import CryptoKit
import Foundation

/// Runs `dsh --profile web` as a child process bound to loopback and reports the URL it prints.
///
/// The browser UI served by this process is the harness's own frontend, so a client that
/// shows this URL gets exactly the official UX. The server is owned by the caller and
/// stopped with ``stop()``. A stale process from a crash is stopped on the next launch.
public final class HarnessWebServer: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var pid: pid_t = 0
    private var stdin: Pipe?
    private var exitSource: DispatchSourceProcess?
    private var stderrTail: [String] = []
    private var timedOut = false
    private var portInUse = false

    private let pidFile: URL?
    private var isReady: (@Sendable (Int) async -> Bool)?

    /// Called on the main queue when the server exits without ``stop()``.
    public var onUnexpectedExit: (@Sendable () -> Void)?

    /// - Parameter pidFile: where the server's pid is recorded. A process left by a crash
    ///   is stopped on the next launch: `dsh --profile web` does not exit with its parent.
    public init(pidFile: URL? = nil) {
        self.pidFile = pidFile
    }

    // MARK: - Recorded server

    private func recorded() -> (pid: pid_t, written: Date)? {
        guard let pidFile, let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let written = (try? FileManager.default.attributesOfItem(atPath: pidFile.path))?[.modificationDate] as? Date
        else { return nil }
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard let first = parts.first, let pid = pid_t(first), pid > 1 else { return nil }
        return (pid, written)
    }

    private func record(pid: pid_t) {
        guard let pidFile else { return }
        try? String(pid).write(to: pidFile, atomically: true, encoding: .utf8)
    }

    /// The recorded pid still belongs to the dsh web server that wrote it: the pid is written right
    /// after launch, so a process started later has reused the pid and is not ours.
    private static func isServer(_ pid: pid_t, writtenAt written: Date) -> Bool {
        guard let started = startDate(of: pid), started <= written.addingTimeInterval(1) else { return false }
        return commandLine(of: pid).contains("--profile web --no-open --host 127.0.0.1")
    }

    /// Stops a recorded server left by a previous app process.
    private func reapLeftover() {
        guard let rec = recorded() else { return }
        if let pidFile { try? FileManager.default.removeItem(at: pidFile) }
        guard Self.isServer(rec.pid, writtenAt: rec.written) else { return }
        Self.terminate(rec.pid, grace: 6)
    }

    static func startDate(of pid: pid_t) -> Date? {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1e6)
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

    /// SIGTERM, then SIGKILL after `grace` seconds. dsh bounds its own teardown at 5 s and uses it
    /// to stop its MCP servers; killing it earlier would orphan them.
    private static func terminate(_ pid: pid_t, grace: TimeInterval) {
        guard kill(pid, SIGTERM) == 0 else { return }
        let deadline = Date().addingTimeInterval(grace)
        while kill(pid, 0) == 0, Date() < deadline { usleep(20_000) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    private func watchExit(of watched: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: watched, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            source.cancel()
            // stop() clears the pid first, so only an exit nobody asked for reports.
            let unexpected = self.lock.withLock { () -> Bool in
                guard self.pid == watched else { return false }
                self.pid = 0; self.process = nil; self.exitSource = nil
                return true
            }
            if unexpected { self.onUnexpectedExit?() }
        }
        lock.withLock { exitSource?.cancel(); exitSource = source }
        source.resume()
        // The process may have exited before the source was armed.
        if kill(watched, 0) != 0 { source.setEventHandler {}; source.cancel() }
    }

    // MARK: - Start

    /// Parses `dsh web: http://127.0.0.1:PORT/?token=…`. Only http on 127.0.0.1, where dsh is bound, is accepted.
    public static func parseURL(line: String) -> URL? {
        guard let marker = line.range(of: "dsh web: ") else { return nil }
        let text = line[marker.upperBound...].split(separator: " ").first.map(String.init) ?? ""
        guard let url = URL(string: text), url.scheme == "http", url.host == "127.0.0.1" else { return nil }
        return url
    }

    /// Name of dsh's session cookie for a server on `port`: `dsh-auth-` + base64url(SHA-256("127.0.0.1:PORT")).
    /// Cookies ignore ports, so every port dsh ever ran on leaves one more on 127.0.0.1; past ~60 the
    /// Cookie header exceeds Node's 16 KB limit and every request, the page included, gets HTTP 431.
    public static func authCookieName(port: Int) -> String {
        let digest = Data(SHA256.hash(data: Data("127.0.0.1:\(port)".utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "dsh-auth-" + digest
    }

    /// Starts a fresh server and returns its authenticated URL. Tries `preferredPort` first (a
    /// stable origin keeps local storage across launches) and falls back to a free port. A boot
    /// silent for `stallTimeout` is restarted once; the retry gets the full `timeout`.
    /// - Parameter isReady: asks a server on a known port whether it finished loading, with the
    ///   client's own session (dsh's 30-day cookie, which outlives the process). dsh sometimes never
    ///   prints its URL although it serves normally; a client that is already signed in then loads
    ///   the root URL as soon as this is true instead of waiting for the stall retry.
    public func start(executable: URL, environment: [String: String], preferredPort: Int = 3179,
                      stallTimeout: TimeInterval = 15, timeout: TimeInterval = 180,
                      isReady: (@Sendable (Int) async -> Bool)? = nil) async throws -> URL {
        lock.withLock { self.isReady = isReady }
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
        let stdin = Pipe()
        proc.standardInput = stdin
        do { try proc.run() } catch { throw HarnessError.launchFailed(error.localizedDescription) }
        lock.withLock { process = proc; pid = proc.processIdentifier; self.stdin = stdin
                        stderrTail = []; timedOut = false; portInUse = false }
        record(pid: proc.processIdentifier)

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
        let isReady = lock.withLock { self.isReady }
        let probe = Task.detached {
            guard let isReady, port != 0 else { return }
            while proc.isRunning {
                try await Task.sleep(for: .milliseconds(500))
                // The port must be served by this process, not by another server left on it.
                if await isReady(port), Self.listener(on: port) == proc.processIdentifier {
                    found.yield(URL(string: "http://127.0.0.1:\(port)/"))
                    return
                }
            }
        }
        defer { probe.cancel() }
        let watchdog = Task.detached { [weak self] in
            try await Task.sleep(for: .seconds(timeout))
            if proc.isRunning {
                self?.lock.withLock { self?.timedOut = true }
                self?.noteStderr("dsh did not print its URL within \(Int(timeout)) s")
                proc.terminate()
                // MCP servers spawned by dsh can hold stdout open after it exits, so the reader may
                // never see EOF; end the wait here instead.
                try await Task.sleep(for: .seconds(6))
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                found.yield(nil)
            }
        }
        defer { watchdog.cancel() }

        // A URL printed after the watchdog fired belongs to a server that is already shutting down.
        for await url in urls {
            if let url, !lock.withLock({ timedOut }), proc.isRunning {
                watchExit(of: proc.processIdentifier)
                return url
            }
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

    /// The pid listening on a loopback TCP port, if any.
    static func listener(on port: Int) -> pid_t? {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-iTCP@127.0.0.1:\(port)", "-sTCP:LISTEN", "-t"]
        let out = Pipe()
        lsof.standardOutput = out
        lsof.standardError = FileHandle.nullDevice
        guard (try? lsof.run()) != nil else { return nil }
        lsof.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").first.flatMap { pid_t($0) }
    }

    private func noteStderr(_ line: String) {
        lock.withLock {
            if line.contains("EADDRINUSE") { portInUse = true }
            stderrTail.append(line)
            if stderrTail.count > 40 { stderrTail.removeFirst(stderrTail.count - 40) }
        }
    }

    // MARK: - Stop

    public var isRunning: Bool { lock.withLock { pid > 0 && kill(pid, 0) == 0 } }

    /// Stops the server (SIGTERM, then SIGKILL after `grace` seconds). Safe from `applicationWillTerminate`.
    public func stop(grace: TimeInterval = 6) {
        let (running, proc) = lock.withLock { () -> (pid_t, Process?) in
            defer { pid = 0; process = nil; exitSource?.cancel(); exitSource = nil }
            return (pid, process)
        }
        guard running > 0 else { return }
        if let pidFile { try? FileManager.default.removeItem(at: pidFile) }
        guard let proc else { return Self.terminate(running, grace: grace) }
        // Our own child is reaped by its Process; polling the pid would see the zombie until then.
        guard proc.isRunning else { return }
        proc.terminate()
        let deadline = Date().addingTimeInterval(grace)
        while proc.isRunning, Date() < deadline { usleep(20_000) }
        if proc.isRunning { kill(running, SIGKILL) }
    }
}
