import Foundation

/// One row of a conversation as the app renders it.
public struct TranscriptItem: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case user(String)
        case assistant(String)
        case thinking(String)
        case tool(ToolCall)
        case notice(String)
    }
    public var id = UUID()
    public var kind: Kind
    public init(kind: Kind) { self.kind = kind }
}

public struct ToolCall: Codable, Hashable, Sendable {
    public var callId: String
    public var name: String
    public var arguments: String
    public var result: String?
    public var isError = false
    /// Decision reported by a PreToolUse hook (`pass`, `deny`, `ask`), when one ran.
    public var gate: String?

    public init(callId: String, name: String, arguments: String) {
        self.callId = callId
        self.name = name
        self.arguments = arguments
    }

    /// The most useful single line of the arguments (the shell command, the path...).
    public var summary: String {
        guard let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return arguments
        }
        for key in ["command", "file_path", "path", "pattern", "url", "query", "prompt", "description"] {
            if let v = obj[key] as? String, !v.isEmpty { return v }
        }
        return arguments
    }
}

/// A conversation. `generation` ties it to the runtime process that owns it: the SDK
/// runtime cannot resume a session after a restart, so older sessions are read-only.
public struct ChatSession: Identifiable, Codable, Hashable, Sendable {
    public var id: String = UUID().uuidString.lowercased()
    public var title = "New session"
    public var createdAt = Date()
    public var provider: String
    public var model: String
    public var workspace: String
    public var generation: Int
    public var items: [TranscriptItem] = []
    public var isRunning = false

    public init(provider: String, model: String, workspace: String, generation: Int) {
        self.provider = provider
        self.model = model
        self.workspace = workspace
        self.generation = generation
    }

    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, provider, model, workspace, generation, items
    }
}

extension ChatSession {
    /// Folds one session event into a session. Pure, so it is easy to reason about.
    public mutating func apply(_ event: SessionEvent) {
        switch event {
        case .assistantMessage(_, let content, _, _, _):
            for block in content {
                switch block {
                case .text(let t) where !t.isEmpty: items.append(TranscriptItem(kind: .assistant(t)))
                case .thinking(let t) where !t.isEmpty: items.append(TranscriptItem(kind: .thinking(t)))
                default: break   // tool calls arrive as their own `tool/call` event
                }
            }
        case .toolCall(let callId, let name, let arguments):
            items.append(TranscriptItem(kind: .tool(ToolCall(callId: callId, name: name, arguments: arguments))))
        case .toolResult(let callId, let content):
            updateTool(callId) { $0.result = content.compactMap(\.plainText).joined(separator: "\n") }
        case .hookResult(let point, let decision, _) where point == "PreToolUse":
            updateLastPendingTool { $0.gate = decision; $0.isError = decision == "deny" }
        case .title(let t) where !t.isEmpty:
            title = t
        case .turnEnd(_, let reason) where reason != "completed":
            items.append(TranscriptItem(kind: .notice("Turn ended: \(reason)")))
        default:
            break
        }
    }


    mutating func updateTool(_ callId: String, _ change: (inout ToolCall) -> Void) {
        guard let i = items.lastIndex(where: { if case .tool(let t) = $0.kind { t.callId == callId } else { false } }),
              case .tool(var call) = items[i].kind else { return }
        change(&call)
        items[i].kind = .tool(call)
    }

    mutating func updateLastPendingTool(_ change: (inout ToolCall) -> Void) {
        guard let i = items.lastIndex(where: { if case .tool(let t) = $0.kind { t.result == nil } else { false } }),
              case .tool(var call) = items[i].kind else { return }
        change(&call)
        items[i].kind = .tool(call)
    }
}

