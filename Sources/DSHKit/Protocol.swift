import Foundation

// Typed mirror of the DeepSeek Harness SDK runtime protocol
// (`@deepseek-ai/dsh-sdk-protocol`): three requests and four notifications
// exchanged as newline-delimited JSON-RPC 2.0 over the `dsh --profile sdk` stdio.

public struct InitializeParams: Codable, Sendable, Equatable {
    public var cwd: String
    public var provider: String
    public var model: String
    public var reasoningEffort: String?
    public var maxTokens: Int?

    public init(cwd: String, provider: String, model: String, reasoningEffort: String? = nil, maxTokens: Int? = nil) {
        self.cwd = cwd
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.maxTokens = maxTokens
    }
}

public struct InitializeResult: Codable, Sendable, Equatable {
    public struct ServerInfo: Codable, Sendable, Equatable {
        public var name: String
        public var version: String
    }
    public var serverInfo: ServerInfo
}

public struct SessionPromptParams: Codable, Sendable, Equatable {
    public var sessionId: String
    public var contentBlocks: [PromptBlock]
}

public struct SessionPromptResult: Codable, Sendable, Equatable {
    public var messageId: String
}

/// Prompt input accepted by `session/prompt`.
public enum PromptBlock: Codable, Sendable, Equatable {
    case text(String)
    case image(base64: String, mimeType: String)

    private enum Keys: String, CodingKey { case type, text, data, mimeType }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .text(let t):
            try c.encode("text", forKey: .type)
            try c.encode(t, forKey: .text)
        case .image(let data, let mime):
            try c.encode("image", forKey: .type)
            try c.encode(data, forKey: .data)
            try c.encode(mime, forKey: .mimeType)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "image":
            self = .image(base64: try c.decode(String.self, forKey: .data),
                          mimeType: try c.decode(String.self, forKey: .mimeType))
        default:
            self = .text(try c.decode(String.self, forKey: .text))
        }
    }
}

/// A content block inside a session message (assistant text, tool calls, tool results...).
public enum ContentBlock: Sendable, Equatable, Decodable {
    case text(String)
    case thinking(String)
    case toolCall(id: String, name: String, arguments: String)
    case toolResult(toolCallId: String, content: [ContentBlock], isError: Bool)
    case other(type: String, raw: JSONValue)

    public init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        self = ContentBlock(raw)
    }

    public init(_ raw: JSONValue) {
        let type = raw["type"]?.stringValue ?? ""
        switch type {
        case "text":
            self = .text(raw["text"]?.stringValue ?? "")
        case "thinking", "reasoning":
            self = .thinking(raw["text"]?.stringValue ?? raw["thinking"]?.stringValue ?? "")
        case "tool-call":
            self = .toolCall(id: raw["id"]?.stringValue ?? "",
                             name: raw["name"]?.stringValue ?? "",
                             arguments: raw["arguments"]?.stringValue ?? "")
        case "tool-result":
            let inner = raw["content"]?.arrayValue?.map(ContentBlock.init) ?? []
            var isError = false
            if case .bool(let b)? = raw["isError"] { isError = b }
            self = .toolResult(toolCallId: raw["toolCallId"]?.stringValue ?? "", content: inner, isError: isError)
        default:
            self = .other(type: type, raw: raw)
        }
    }

    /// Plain text carried by this block, if any.
    public var plainText: String? {
        switch self {
        case .text(let t), .thinking(let t): return t
        case .toolResult(_, let content, _): return content.compactMap(\.plainText).joined(separator: "\n")
        default: return nil
        }
    }
}

/// One session-log event, decoded into the cases a client renders.
/// Anything else is preserved as `.other` so newer runtimes never break decoding.
public enum SessionEvent: Sendable, Equatable {
    case userMessage(id: String, content: [ContentBlock], fromUser: Bool)
    case assistantMessage(id: String, content: [ContentBlock], provider: String?, model: String?, usage: Usage?)
    case toolCall(callId: String, name: String, arguments: String)
    case toolResult(callId: String, content: [ContentBlock])
    case turnStart(turn: Int)
    case turnEnd(turn: Int, reason: String)
    case title(String)
    case hookResult(point: String, decision: String, summary: String?)
    case other(type: String)

    public struct Usage: Sendable, Equatable {
        public var inputTokens: Int?
        public var outputTokens: Int?
        public var totalTokens: Int?
    }

    public init(_ event: JSONValue) {
        let type = event["type"]?.stringValue ?? ""
        let data = event["data"] ?? .null
        let message = data["message"] ?? .null
        let blocks = message["content"]?.arrayValue?.map(ContentBlock.init) ?? []
        switch type {
        case "user/message":
            self = .userMessage(id: data["id"]?.stringValue ?? "",
                                content: data["content"]?.arrayValue?.map(ContentBlock.init) ?? [],
                                fromUser: data["source"]?["kind"]?.stringValue == "user")
        case "assistant/message":
            let u = data["usage"]
            self = .assistantMessage(
                id: message["id"]?.stringValue ?? "",
                content: blocks,
                provider: message["source"]?["provider"]?.stringValue,
                model: message["source"]?["model"]?.stringValue,
                usage: u.map { Usage(inputTokens: $0["inputTokens"]?.intValue,
                                     outputTokens: $0["outputTokens"]?.intValue,
                                     totalTokens: $0["totalTokens"]?.intValue) })
        case "tool/call":
            self = .toolCall(callId: data["callId"]?.stringValue ?? "",
                             name: data["name"]?.stringValue ?? "",
                             arguments: data["arguments"]?.stringValue ?? "")
        case "tool/result":
            let callId = message["source"]?["callId"]?.stringValue ?? ""
            let inner = blocks.flatMap { block -> [ContentBlock] in
                if case .toolResult(_, let content, _) = block { return content }
                return [block]
            }
            self = .toolResult(callId: callId, content: inner)
        case "turn/start":
            self = .turnStart(turn: data["turn"]?.intValue ?? 0)
        case "turn/end":
            self = .turnEnd(turn: data["turn"]?.intValue ?? 0, reason: data["reason"]?["kind"]?.stringValue ?? "")
        case "session/title":
            self = .title(data["title"]?.stringValue ?? "")
        case "hook/result":
            self = .hookResult(point: data["point"]?.stringValue ?? "",
                               decision: data["decision"]?.stringValue ?? "",
                               summary: data["stderrSummary"]?.stringValue)
        default:
            self = .other(type: type)
        }
    }
}

public enum AgentStatus: String, Sendable, Codable {
    case idle, running
}

/// Server-to-client notifications.
public enum HarnessNotification: Sendable, Equatable {
    case event(sessionId: String, SessionEvent)
    case status(sessionId: String, AgentStatus)
    case subagentStarted(parentSessionId: String, childSessionId: String)
    case subagentFinished(parentSessionId: String, childSessionId: String, provider: String, ok: Bool)
    case unknown(method: String)

    public init(method: String, params: JSONValue) {
        switch method {
        case "session.event":
            self = .event(sessionId: params["sessionId"]?.stringValue ?? "", SessionEvent(params["event"] ?? .null))
        case "session.status":
            self = .status(sessionId: params["sessionId"]?.stringValue ?? "",
                           AgentStatus(rawValue: params["status"]?.stringValue ?? "") ?? .idle)
        case "subagent.started":
            self = .subagentStarted(parentSessionId: params["parentSessionId"]?.stringValue ?? "",
                                    childSessionId: params["childSessionId"]?.stringValue ?? "")
        case "subagent.finished":
            self = .subagentFinished(parentSessionId: params["parentSessionId"]?.stringValue ?? "",
                                     childSessionId: params["childSessionId"]?.stringValue ?? "",
                                     provider: params["provider"]?.stringValue ?? "",
                                     ok: params["status"]?.stringValue == "ok")
        default:
            self = .unknown(method: method)
        }
    }
}
