import Foundation

/// Runs `dsh --profile web` as a child process bound to loopback and reports the URL it prints.
///
/// The browser UI served by this process is the harness's own frontend, so a client that
/// shows this URL gets exactly the official UX. The server is owned by the caller and
/// stopped with ``stop()``.
public final class HarnessWebServer: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stdin: Pipe?
    private var stderrTail: [String] = []
    private var timedOut = false
    private var portInUse = false

    private let pidFile: URL?

    /// - Parameter pidFile: where the server's pid is recorded, so a server left behind by a crash
    ///   or force quit is stopped on the next launch. `dsh --profile web` does not exit when its
    ///   parent dies, and a leftover instance makes the next one boot for minutes.
    public init(pidFile: URL? = nil) {
        self.pidFile = pidFile
    }

    /// Stops a server recorded in `pidFile` by an earlier run, if it is still a dsh web server.
    private func reapLeftover() {
        guard let pidFile, let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        try? FileManager.default.removeItem(at: pidFile)
        guard Self.commandLine(of: pid).contains("--profile web --no-open --host 127.0.0.1") else { return }
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(6)
        while kill(pid, 0) == 0, Date() < deadline { usleep(50_000) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    static func commandLine(of pid: pid_t) -> String {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "command=", "-p", String(pid)]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return "" }
        ps.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// Parses `dsh web: http://127.0.0.1:PORT/?token=…`. Only loopback http URLs are accepted.
    public static func parseURL(line: String) -> URL? {
        guard let marker = line.range(of: "dsh web: ") else { return nil }
        let text = line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: text), url.scheme == "http",
              let host = url.host, ["127.0.0.1", "localhost", "::1"].contains(host) else { return nil }
        return url
    }

    /// Starts the server and waits for its URL. Tries `preferredPort` first (a stable origin keeps
    /// the web UI's local storage across launches) and falls back to a free port chosen by the OS.
    /// A boot silent for `stallTimeout` is restarted once; the retry gets the full `timeout`.
    public func start(executable: URL, environment: [String: String], preferredPort: Int = 3179,
                      stallTimeout: TimeInterval = 30, timeout: TimeInterval = 180) async throws -> URL {
        // A healthy boot takes seconds. Now and then a boot stalls before printing its URL and never
        // recovers, while the next one is quick again, so one stalled attempt is retried once.
        do {
            return try await launchOnAnyPort(executable, environment, preferredPort, stallTimeout)
        } catch HarnessError.processExited where lock.withLock({ timedOut }) {
            return try await launchOnAnyPort(executable, environment, preferredPort, timeout)
        }
    }

    private func launchOnAnyPort(_ executable: URL, _ environment: [String: String],
                                 _ preferredPort: Int, _ timeout: TimeInterval) async throws -> URL {
        do {
            return try await launch(executable, environment, port: preferredPort, timeout: timeout)
        } catch HarnessError.processExited where preferredPort != 0 && lock.withLock({ portInUse }) {
            return try await launch(executable, environment, port: 0, timeout: timeout)
        }
    }

    private func launch(_ executable: URL, _ environment: [String: String],
                        port: Int, timeout: TimeInterval) async throws -> URL {
        stop()
        reapLeftover()
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = ["--profile", "web", "--no-open", "--host", "127.0.0.1", "--port", String(port)]
        proc.environment = environment
        proc.currentDirectoryURL = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory())
        // Children inherit the parent's QoS; a backgrounded app would otherwise start dsh and its
        // MCP servers at background priority, and boot takes minutes instead of seconds.
        proc.qualityOfService = .userInitiated
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        // An open stdin keeps dsh alive: at EOF (e.g. /dev/null) it may shut down right after
        // printing its URL. The pipe also closes when this app dies, taking dsh with it.
        let stdin = Pipe()
        proc.standardInput = stdin
        do { try proc.run() } catch { throw HarnessError.launchFailed(error.localizedDescription) }
        lock.withLock { process = proc; self.stdin = stdin; stderrTail = []; timedOut = false; portInUse = false }
        if let pidFile { try? String(proc.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8) }

        // Both pipes are drained for the life of the process, otherwise a full pipe blocks dsh.
        let (urls, found) = AsyncStream<URL?>.makeStream()
        Task.detached {
            do { for try await line in out.fileHandleForReading.bytes.lines {
                if let url = Self.parseURL(line: line) { found.yield(url) }
            } } catch {}
            found.yield(nil)
            found.finish()
        }
        let stderrDrained = Task.detached { [weak self] in
            do { for try await line in err.fileHandleForReading.bytes.lines { self?.noteStderr(line) } } catch {}
        }
        let watchdog = Task.detached { [weak self] in
            try await Task.sleep(for: .seconds(timeout))
            if proc.isRunning {
                self?.lock.withLock { self?.timedOut = true }
                self?.noteStderr("dsh did not print its URL within \(Int(timeout)) s")
                proc.terminate()
            }
        }
        defer { watchdog.cancel() }

        // A URL printed after the watchdog fired belongs to a server that is already shutting down.
        for await url in urls {
            if let url, !lock.withLock({ timedOut }) { return url }
            break
        }
        proc.waitUntilExit()
        // The exit can be observed before the last stderr lines are read. MCP servers spawned by
        // dsh may keep the pipe open, so the wait is bounded.
        _ = await Task { await withTaskGroup(of: Void.self) { group in
            group.addTask { await stderrDrained.value }
            group.addTask { try? await Task.sleep(for: .seconds(1)) }
            await group.next()
            group.cancelAll()
        } }.value
        let tail = lock.withLock { stderrTail.suffix(8).joined(separator: "\n") }
        throw HarnessError.processExited(status: proc.terminationStatus, stderrTail: tail)
    }

    private func noteStderr(_ line: String) {
        lock.withLock {
            if line.contains("EADDRINUSE") { portInUse = true }
            stderrTail.append(line)
            if stderrTail.count > 40 { stderrTail.removeFirst(stderrTail.count - 40) }
        }
    }

    public var isRunning: Bool { lock.withLock { process?.isRunning ?? false } }

    /// SIGTERM, then SIGKILL after `grace` seconds. dsh bounds its own teardown at 5 s and uses it to
    /// stop its MCP servers; killing it earlier would orphan them. Safe from `applicationWillTerminate`.
    public func stop(grace: TimeInterval = 6) {
        guard let proc = lock.withLock({ () -> Process? in defer { process = nil }; return process }) else { return }
        if let pidFile { try? FileManager.default.removeItem(at: pidFile) }
        guard proc.isRunning else { return }
        proc.terminate()
        let deadline = Date().addingTimeInterval(grace)
        while proc.isRunning, Date() < deadline { usleep(20_000) }
        if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
    }
}
