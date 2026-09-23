import Foundation
import Testing
@testable import DSHKit

// Fixtures are synthetic frames in the shape of the SDK wire protocol.

private func json(_ s: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
}

@Suite struct Framing {
    @Test func splitsCompleteLinesAndKeepsRemainder() {
        var s = LineSplitter()
        #expect(s.append(Data("{\"a\":1}\n{\"b\"".utf8)).count == 1)
        let rest = s.append(Data(":2}\r\n\n".utf8))
        #expect(rest == [Data("{\"b\":2}".utf8)])
    }

    @Test func dropsOversizedPartialFrame() {
        var s = LineSplitter(maxFrameBytes: 8)
        #expect(s.append(Data("0123456789".utf8)).isEmpty)
        #expect(s.append(Data("ok\n".utf8)) == [Data("ok".utf8)])
    }

    @Test func encodesRequestAsSingleTerminatedLine() throws {
        let data = try HarnessRuntime.encodeRequest(
            id: 7, method: "session/prompt",
            params: SessionPromptParams(sessionId: "s1", contentBlocks: [.text("hi")]))
        #expect(data.last == 0x0A)
        #expect(data.dropLast().contains(0x0A) == false)
        let v = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(v["jsonrpc"]?.stringValue == "2.0")
        #expect(v["id"]?.intValue == 7)
        #expect(v["params"]?["contentBlocks"]?.arrayValue?.first?["type"]?.stringValue == "text")
    }
}

@Suite struct Events {
    @Test func decodesAssistantToolCallAndText() throws {
        let n = HarnessNotification(method: "session.event", params: try json("""
        {"sessionId":"s1","event":{"type":"assistant/message","seq":3,"data":{"turn":1,"step":1,
         "message":{"role":"assistant","id":"m1","source":{"kind":"model","provider":"p","model":"m"},
         "content":[{"type":"text","text":"hello"},
                    {"type":"tool-call","id":"c1","name":"bash","arguments":"{\\"command\\":\\"ls\\"}"}]},
         "usage":{"inputTokens":2,"outputTokens":5,"totalTokens":7}}}}
        """))
        guard case .event(let sid, .assistantMessage(let id, let content, let provider, let model, let usage)) = n else {
            Issue.record("unexpected \(n)"); return
        }
        #expect(sid == "s1" && id == "m1" && provider == "p" && model == "m")
        #expect(usage?.outputTokens == 5)
        #expect(content == [.text("hello"), .toolCall(id: "c1", name: "bash", arguments: "{\"command\":\"ls\"}")])
    }

    @Test func decodesToolResultUnwrappingInnerContent() throws {
        let e = SessionEvent(try json("""
        {"type":"tool/result","data":{"message":{"role":"user","source":{"kind":"tool","callId":"c1"},
         "content":[{"type":"tool-result","toolCallId":"c1","isError":false,"content":[{"type":"text","text":"out\\n"}]}]}}}
        """))
        #expect(e == .toolResult(callId: "c1", content: [.text("out\n")]))
    }

    @Test func marksOnlyRealUserMessagesAsFromUser() throws {
        let user = SessionEvent(try json(#"{"type":"user/message","data":{"id":"u","content":[{"type":"text","text":"hi"}],"source":{"kind":"user"}}}"#))
        let injected = SessionEvent(try json(#"{"type":"user/message","data":{"id":"x","content":[],"source":{"kind":"plugin"}}}"#))
        #expect(user == .userMessage(id: "u", content: [.text("hi")], fromUser: true))
        guard case .userMessage(_, _, false) = injected else { Issue.record("injected context must not be user"); return }
    }

    @Test func unknownEventsAndMethodsDoNotFail() throws {
        #expect(SessionEvent(try json(#"{"type":"future/thing","data":{}}"#)) == .other(type: "future/thing"))
        #expect(HarnessNotification(method: "x.y", params: .null) == .unknown(method: "x.y"))
    }

    @Test func decodesStatusAndTurnEnd() throws {
        #expect(HarnessNotification(method: "session.status", params: try json(#"{"sessionId":"s","status":"running"}"#))
                == .status(sessionId: "s", .running))
        #expect(SessionEvent(try json(#"{"type":"turn/end","data":{"turn":2,"reason":{"kind":"completed"}}}"#))
                == .turnEnd(turn: 2, reason: "completed"))
    }
}

@Suite struct Settings {
    @Test func readsRoutesAndDefault() {
        let s = HarnessSettings.parse(yaml: """
        agent-default-model:
          provider: my-gateway
          model: big-model
        llm-pi-ai:
          providers:
            my-gateway:
              displayName: My Gateway
              api: openai-completions
              baseURL: http://127.0.0.1:9999/v1
              models:
                - id: big-model
                - id: small-model
        """)
        #expect(s.defaultModel == ModelChoice(provider: "my-gateway", model: "big-model", providerLabel: "My Gateway"))
        #expect(s.models.prefix(2).map(\.model) == ["big-model", "small-model"])
        #expect(s.models.contains { $0.provider == "deepseek-official" })
    }

    @Test func emptyOrInvalidYamlFallsBackToBuiltIns() {
        #expect(HarnessSettings.parse(yaml: "::: not yaml").models == HarnessSettings.builtIn)
        #expect(HarnessSettings.parse(yaml: "").defaultModel == HarnessSettings.builtIn.first)
    }
}

@Suite struct Environment {
    @Test func fallbackPathAddsUsualLocations() {
        let env = HarnessEnvironment.withFallbackPath(["HOME": "/Users/x", "PATH": "/usr/bin"])
        #expect(env["PATH"]!.hasPrefix("/usr/bin:"))
        #expect(env["PATH"]!.contains("/opt/homebrew/bin"))
    }
}

@Suite struct TranscriptReducer {
    @Test func foldsToolCallGateResultAndTitle() {
        var s = ChatSession(provider: "p", model: "m", workspace: "/tmp", generation: 1)
        s.apply(.title("List files"))
        s.apply(.assistantMessage(id: "a", content: [.toolCall(id: "c1", name: "bash", arguments: #"{"command":"ls"}"#)],
                                  provider: nil, model: nil, usage: nil))
        s.apply(.toolCall(callId: "c1", name: "bash", arguments: #"{"command":"ls"}"#))
        s.apply(.hookResult(point: "PreToolUse", decision: "deny", summary: nil))
        s.apply(.toolResult(callId: "c1", content: [.text("blocked")]))
        s.apply(.assistantMessage(id: "b", content: [.text("Done.")], provider: nil, model: nil, usage: nil))
        s.apply(.turnEnd(turn: 1, reason: "completed"))

        #expect(s.title == "List files")
        #expect(s.items.count == 2)                     // tool card + final text; no duplicate card
        guard case .tool(let call) = s.items[0].kind else { Issue.record("expected tool"); return }
        #expect(call.summary == "ls" && call.gate == "deny" && call.isError && call.result == "blocked")
        #expect(s.items[1].kind == .assistant("Done."))
    }

    @Test func nonCompletedTurnLeavesANotice() {
        var s = ChatSession(provider: "p", model: "m", workspace: "/tmp", generation: 1)
        s.apply(.turnEnd(turn: 1, reason: "error"))
        #expect(s.items.map(\.kind) == [.notice("Turn ended: error")])
    }

    @Test func sessionRoundTripsThroughJSONWithoutRuntimeState() throws {
        var s = ChatSession(provider: "p", model: "m", workspace: "/tmp", generation: 3)
        s.isRunning = true
        s.apply(.assistantMessage(id: "a", content: [.text("hi")], provider: nil, model: nil, usage: nil))
        let back = try JSONDecoder().decode(ChatSession.self, from: JSONEncoder().encode(s))
        #expect(back.items == s.items && back.isRunning == false)
    }
}

@Suite struct WebServerURL {
    @Test func acceptsOnlyLoopbackHTTP() {
        #expect(HarnessWebServer.parseURL(line: "dsh web: http://127.0.0.1:3179/?token=abc")?.port == 3179)
        #expect(HarnessWebServer.parseURL(line: "dsh web: http://localhost:8080/") == nil)
        #expect(HarnessWebServer.parseURL(line: "dsh web: http://0.0.0.0:3179/") == nil)
        #expect(HarnessWebServer.parseURL(line: "dsh web: https://example.com/") == nil)
        #expect(HarnessWebServer.parseURL(line: "listening on 3179") == nil)
    }

    @Test func startDateOfSelfIsInThePast() throws {
        let started = try #require(HarnessWebServer.startDate(of: getpid()))
        #expect(started <= Date() && started > Date().addingTimeInterval(-3600))
        #expect(HarnessWebServer.startDate(of: 999_999) == nil)
    }
}
@Suite struct WebServerAuthCookie {
    @Test func matchesDshsCookieName() {
        // Set-Cookie of a real `dsh --profile web --port 3198`.
        #expect(HarnessWebServer.authCookieName(port: 3198) == "dsh-auth-RzlCo9Rz1yz29BFrRc8m_0rXfRC1EWk-c9YQI4BxrWM")
    }
}

@Suite struct WebServerURLLine {
    @Test func ignoresTheLANSuffix() {
        let url = HarnessWebServer.parseURL(line: "dsh web: http://127.0.0.1:3179/?token=abc (LAN: http://192.168.0.2:3179/?token=abc)")
        #expect(url?.absoluteString == "http://127.0.0.1:3179/?token=abc")
    }
}
