import Foundation

public enum HarnessError: Error, LocalizedError, Sendable, Equatable {
    case notRunning
    case launchFailed(String)
    case rpc(code: Int, message: String)
    case processExited(status: Int32, stderrTail: String)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .notRunning: return "The dsh runtime is not running."
        case .launchFailed(let why): return "Could not start dsh: \(why)"
        case .rpc(let code, let message): return "dsh error \(code): \(message)"
        case .processExited(let status, let tail):
            return "dsh exited with status \(status)." + (tail.isEmpty ? "" : "\n\(tail)")
        case .malformedResponse: return "dsh sent a response the client could not read."
        }
    }
}

/// One `dsh --profile sdk` process and the JSON-RPC session on top of it.
///
/// Frames are processed strictly in arrival order by a single consumer task, so
/// `notifications` preserves the runtime's event order.
public actor HarnessRuntime {
    public nonisolated let notifications: AsyncStream<HarnessNotification>
    private let notify: AsyncStream<HarnessNotification>.Continuation

    private var process: Process?
    private var input: FileHandle?
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var stderrTail = ""
    private var consumer: Task<Void, Never>?

    public init() {
        (notifications, notify) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    public var isRunning: Bool { process?.isRunning ?? false }

    /// Launches `dsh --profile sdk` and performs the `initialize` handshake.
    public func start(executable: URL,
                      environment: [String: String],
                      params: InitializeParams,
                      extraArguments: [String] = []) async throws -> InitializeResult {
        guard process == nil else { throw HarnessError.launchFailed("already running") }

        let proc = Process()
        proc.executableURL = executable
        proc.arguments = ["--profile", "sdk"] + extraArguments
        proc.environment = environment
        proc.currentDirectoryURL = URL(fileURLWithPath: params.cwd, isDirectory: true)
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        let (lines, lineSink) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        let splitter = LockedSplitter()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                lineSink.finish()
                return
            }
            for line in splitter.append(chunk) { lineSink.yield(line) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else {
                handle.readabilityHandler = nil
                return
            }
            Task { await self?.appendStderr(text) }
        }
        proc.terminationHandler = { [weak self] p in
            Task { await self?.didTerminate(status: p.terminationStatus) }
        }

        do { try proc.run() } catch { throw HarnessError.launchFailed(error.localizedDescription) }
        process = proc
        input = stdinPipe.fileHandleForWriting
        consumer = Task { [weak self] in
            for await line in lines { await self?.handle(line) }
        }

        let raw = try await request("initialize", params: params)
        return try raw.decode(InitializeResult.self)
    }

    /// Queues one user turn. Unknown session ids create a new session.
    public func prompt(sessionId: String, blocks: [PromptBlock]) async throws -> SessionPromptResult {
        let raw = try await request("session/prompt", params: SessionPromptParams(sessionId: sessionId, contentBlocks: blocks))
        return try raw.decode(SessionPromptResult.self)
    }

    /// Asks the runtime to dispose itself, then terminates the process if it lingers.
    public func shutdown(grace: Duration = .seconds(3)) async {
        guard let proc = process else { return }
        _ = try? await withTimeout(grace) { try await self.request("shutdown", params: EmptyParams()) }
        if proc.isRunning { proc.terminate() }
    }

    // MARK: - Wire

    private struct EmptyParams: Encodable {}

    private func request<P: Encodable>(_ method: String, params: P) async throws -> JSONValue {
        guard let input, process?.isRunning == true else { throw HarnessError.notRunning }
        let id = nextId
        nextId += 1
        let frame = try Self.encodeRequest(id: id, method: method, params: params)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            do { try input.write(contentsOf: frame) } catch {
                pending[id] = nil
                cont.resume(throwing: HarnessError.notRunning)
            }
        }
    }

    static func encodeRequest<P: Encodable>(id: Int, method: String, params: P) throws -> Data {
        var data = try JSONEncoder().encode(RPCRequest(id: id, method: method, params: params))
        data.append(0x0A)
        return data
    }

    private func handle(_ line: Data) {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else { return }
        let method = message["method"]?.stringValue
        if let method {
            if message["id"] != nil {
                // Server-initiated requests are not part of the SDK surface: refuse them.
                respondMethodNotFound(id: message["id"]!)
            } else {
                notify.yield(HarnessNotification(method: method, params: message["params"] ?? .null))
            }
            return
        }
        guard let id = message["id"]?.intValue, let cont = pending.removeValue(forKey: id) else { return }
        if let error = message["error"] {
            cont.resume(throwing: HarnessError.rpc(code: error["code"]?.intValue ?? -1,
                                                   message: error["message"]?.stringValue ?? "unknown error"))
        } else {
            cont.resume(returning: message["result"] ?? .null)
        }
    }

    private func respondMethodNotFound(id: JSONValue) {
        let reply: JSONValue = .object(["jsonrpc": .string("2.0"), "id": id,
                                        "error": .object(["code": .number(-32601), "message": .string("Method not found")])])
        guard var data = try? JSONEncoder().encode(reply) else { return }
        data.append(0x0A)
        try? input?.write(contentsOf: data)
    }

    private func appendStderr(_ text: String) {
        stderrTail = String((stderrTail + text).suffix(4000))
    }

    private func didTerminate(status: Int32) {
        let error = HarnessError.processExited(status: status, stderrTail: stderrTail)
        for (_, cont) in pending { cont.resume(throwing: error) }
        pending.removeAll()
        process = nil
        input = nil
        consumer?.cancel()
    }
}

struct RPCRequest<Params: Encodable>: Encodable {
    var jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: Params
}

/// Thread-safe wrapper so the pipe callback (a background queue) can own a splitter.
private final class LockedSplitter: @unchecked Sendable {
    private var splitter = LineSplitter()
    private let lock = NSLock()
    func append(_ chunk: Data) -> [Data] {
        lock.withLock { splitter.append(chunk) }
    }
}

enum TimeoutError: Error { case timedOut }

func withTimeout<T: Sendable>(_ duration: Duration, _ work: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TimeoutError.timedOut
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}
