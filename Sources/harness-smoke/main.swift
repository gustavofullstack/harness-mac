import DSHKit
import Foundation

// End-to-end smoke test against a real `dsh`: starts the SDK runtime, sends one
// prompt, prints the folded transcript and exits non-zero on failure.
// Usage: harness-smoke <provider> <model> "<prompt>" [workspace]
let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("usage: harness-smoke <provider> <model> \"<prompt>\" [workspace]\n".utf8))
    exit(2)
}
let env = HarnessEnvironment.loginShell()
guard let dsh = HarnessEnvironment.locateDSH(in: env) else { print("dsh not found on PATH"); exit(1) }
let workspace = args.count > 4 ? args[4] : FileManager.default.currentDirectoryPath

let runtime = HarnessRuntime()
let started = Date()
do {
    let info = try await runtime.start(executable: dsh, environment: env,
                                       params: InitializeParams(cwd: workspace, provider: args[1], model: args[2]))
    print("server:", info.serverInfo.name, info.serverInfo.version)
    var session = ChatSession(provider: args[1], model: args[2], workspace: workspace, generation: 1)
    let receipt = try await runtime.prompt(sessionId: session.id, blocks: [.text(args[3])])
    print("queued:", receipt.messageId)
    var sawRunning = false
    for await note in runtime.notifications {
        switch note {
        case .event(let sid, let event) where sid == session.id: session.apply(event)
        case .status(let sid, .running) where sid == session.id: sawRunning = true
        case .status(let sid, .idle) where sid == session.id && sawRunning:
            for item in session.items {
                switch item.kind {
                case .assistant(let t): print("assistant:", t)
                case .tool(let c): print("tool:", c.name, "|", c.summary, "| gate:", c.gate ?? "-", "| result:", (c.result ?? "").prefix(200))
                case .notice(let n): print("notice:", n)
                default: break
                }
            }
            print(String(format: "elapsed: %.1fs", Date().timeIntervalSince(started)))
            await runtime.shutdown()
            exit(session.items.contains { if case .assistant = $0.kind { true } else { false } } ? 0 : 1)
        default: break
        }
    }
} catch {
    print("error:", error.localizedDescription)
    await runtime.shutdown()
    exit(1)
}
