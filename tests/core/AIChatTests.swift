import Foundation
import Testing
@testable import ZephyrCore

/// The two streaming wire formats, from recorded event lines (design §10): text arrives as it
/// streams, tool input is assembled and validated, and the assistant turn sent back keeps thinking
/// blocks with their signatures.
@Suite struct StreamParserTests {
    func lines(_ events: [[String: Any]]) -> [String] {
        events.map { "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
    }

    @Test func anthropicTextThinkingAndToolUse() throws {
        var p = StreamParser.anthropic()
        let input = #"{"summary":"Fix date","edits":[{"find":"Monday","replace":"Friday"}]}"#
        let half = input.index(input.startIndex, offsetBy: 20)
        var events: [StreamParser.Event] = []
        for line in ["event: message_start"] + lines([
            ["type": "message_start", "message": ["id": "msg_1"]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "sig"]],
            ["type": "content_block_stop", "index": 0],
            ["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": ""]],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": "Sure, "]],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": "here it is."]],
            ["type": "content_block_stop", "index": 1],
            ["type": "content_block_start", "index": 2, "content_block": ["type": "tool_use", "id": "toolu_1", "name": "propose_patch", "input": [:]]],
            ["type": "content_block_delta", "index": 2, "delta": ["type": "input_json_delta", "partial_json": String(input[..<half])]],
            ["type": "content_block_delta", "index": 2, "delta": ["type": "input_json_delta", "partial_json": String(input[half...])]],
            ["type": "content_block_stop", "index": 2],
            ["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 30]],
            ["type": "message_stop"],
        ]) { events += p.feed(line) }
        #expect(events == [.text("Sure, "), .text("here it is."), .toolCall(id: "toolu_1", name: "propose_patch", json: input), .stop("tool_use")])
        let content = try #require(p.assistantMessage()?["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["thinking", "text", "tool_use"])
        #expect(content[0]["signature"] as? String == "sig")
        #expect((content[2]["input"] as? [String: Any])?["summary"] as? String == "Fix date")
        #expect(p.toolCallIDs == ["toolu_1"])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        let request = try DocumentTools.request("propose_patch", arguments: object).get()
        #expect(request.summary == "Fix date" && request.edits == [ProposedEdit(find: "Monday", replace: "Friday")])
        #expect((try? DocumentTools.request("propose_patch", arguments: ["summary": "x", "edits": [["find": "a"]]]).get()) == nil, "incomplete input is rejected")
        #expect((try? DocumentTools.request("read", arguments: ["lines": ["1", 2]]).get()) == nil, "wrong types are refused, not coerced")
    }

    @Test func cancelledBlocksAreNotSentBack() {
        var p = StreamParser.anthropic()
        for line in lines([
            ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]],
            ["type": "content_block_start", "index": 1, "content_block": ["type": "text", "text": ""]],
        ]) { _ = p.feed(line) }
        #expect(p.assistantMessage() == nil, "unsigned thinking and empty text are dropped")
    }

    /// A call cut off by a cancel would need a result that can never be sent: it is dropped, and a
    /// turn left with nothing else is dropped too (both wire formats).
    @Test func partialToolCallsAreNotSentBack() {
        var a = StreamParser.anthropic()
        for line in lines([
            ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Reading"]],
            ["type": "content_block_stop", "index": 0],
            ["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "toolu_x", "name": "read", "input": [:]]],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": #"{"lines":[1,"#]],
        ]) { _ = a.feed(line) }
        let content = a.assistantMessage()?["content"] as? [[String: Any]]
        #expect(content?.map { $0["type"] as? String } == ["text"] && a.toolCallIDs.isEmpty)

        var o = StreamParser.openAI()
        for line in lines([["choices": [["delta": ["tool_calls": [["index": 0, "id": "call_x", "type": "function", "function": ["name": "read", "arguments": "{"]]]]]]]]) { _ = o.feed(line) }
        #expect(o.assistantMessage() == nil, "no text and no finished call")
    }

    @Test func openAITextAndToolCalls() throws {
        var p = StreamParser.openAI()
        var events: [StreamParser.Event] = []
        for line in lines([
            ["choices": [["delta": ["role": "assistant", "content": "Hi"]]]],
            ["choices": [["delta": ["tool_calls": [["index": 0, "id": "call_1", "type": "function", "function": ["name": "propose_patch", "arguments": "{\"summary\":\"s\","]]]]]]],
            ["choices": [["delta": ["tool_calls": [["index": 0, "function": ["arguments": "\"edits\":[{\"find\":\"a\",\"replace\":\"b\"}]}"]]]]]]],
            ["choices": [["delta": [:], "finish_reason": "tool_calls"]]],
        ]) + ["data: [DONE]"] { events += p.feed(line) }
        #expect(events.first == .text("Hi"))
        #expect(events.dropFirst().first == .toolCall(id: "call_1", name: "propose_patch", json: #"{"summary":"s","edits":[{"find":"a","replace":"b"}]}"#))
        #expect(events.last == .stop("tool_use"))
        let message = try #require(p.assistantMessage())
        #expect(message["content"] as? String == "Hi")
        #expect((message["tool_calls"] as? [[String: Any]])?.first?["id"] as? String == "call_1")
    }
}

/// Answers requests from a script instead of the network, and records what was sent.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var replies: [(status: Int, body: String)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [[String: Any]] = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stub.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            Self.bodies.append((try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
        }
        let reply = Self.replies.removeFirst()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: ["content-type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
@Suite(.serialized) struct AIChatRequestTests {
    func sse(_ events: [[String: Any]]) -> String {
        events.map { "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n\n" }.joined()
    }

    func run(_ chat: AIChat, _ text: String, results: [String: String] = [:]) async -> [AIChat.Event] {
        var events: [AIChat.Event] = []
        chat.onEvent = { events.append($0) }
        chat.send(text, results: results)
        while chat.isStreaming { try? await Task.sleep(nanoseconds: 5_000_000) }
        return events
    }

    @Test func anthropicTurnsProposalsAndRollback() async {
        URLProtocol.registerClass(StubProtocol.self)
        defer { URLProtocol.unregisterClass(StubProtocol.self) }
        StubProtocol.requests = []
        StubProtocol.bodies = []
        let input = #"{"summary":"s","edits":[{"find":"a","replace":"b"}]}"#
        StubProtocol.replies = [
            (200, sse([["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
                       ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "OK"]],
                       ["type": "content_block_stop", "index": 0],
                       ["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "toolu_9", "name": "propose_patch", "input": [:]]],
                       ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": input]],
                       ["type": "content_block_stop", "index": 1],
                       ["type": "message_delta", "delta": ["stop_reason": "tool_use"]]])),
            (401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#),
            (200, sse([["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
                       ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Done"]],
                       ["type": "content_block_stop", "index": 0],
                       ["type": "message_delta", "delta": ["stop_reason": "end_turn"]]])),
        ]
        let chat = AIChat(endpoint: AIEndpoint(kind: .anthropic, baseURL: "https://stub.test", model: "claude-opus-5-5"), apiKey: "sk-test", system: "sys")
        let first = await run(chat, "change a")
        #expect(first.contains { if case .proposal(id: "toolu_9", summary: "s", edits: [ProposedEdit(find: "a", replace: "b")], baseRevision: nil) = $0 { true } else { false } })
        let request = StubProtocol.requests[0]
        #expect(request.url?.path == "/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test" && request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil, "server-side fallback only on api.anthropic.com")
        let body = StubProtocol.bodies[0]
        #expect(body["model"] as? String == "claude-opus-5-5" && body["stream"] as? Bool == true && body["system"] as? String == "sys")
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "medium")
        #expect(((body["tools"] as? [[String: Any]])?.first)?["eager_input_streaming"] as? Bool == true)

        // A rejected request is taken back: the next one still answers the tool call, once.
        let failed = await run(chat, "again", results: ["toolu_9": "applied"])
        #expect(failed.contains { if case let .failed(m) = $0 { m.contains("401") } else { false } })
        _ = await run(chat, "again", results: ["toolu_9": "applied"])
        let messages = StubProtocol.bodies[2]["messages"] as? [[String: Any]] ?? []
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let last = messages.last?["content"] as? [[String: Any]] ?? []
        #expect(last.first?["type"] as? String == "tool_result" && last.first?["tool_use_id"] as? String == "toolu_9" && last.first?["content"] as? String == "applied")
    }
}

/// The one tool contract shared by the built-in AI, the CLI and MCP (design §21.6).
@Suite struct DocumentToolsTests {
    @Test func definitionsMatchAcrossTransports() {
        #expect(DocumentTools.Name.allCases.map(\.rawValue) == ["get_context", "search", "read", "propose_patch"])
        let mcp = DocumentTools.definition(.read, session: true).schema["properties"] as? [String: Any]
        let ai = DocumentTools.definition(.read, session: false).schema["properties"] as? [String: Any]
        #expect(mcp?["session"] != nil && ai?["session"] == nil, "only out-of-process transports name a session")
        #expect(Set((mcp ?? [:]).keys.filter { $0 != "session" }) == Set((ai ?? [:]).keys))
    }

    @Test func argumentsAreCheckedNotCoerced() throws {
        let read = try DocumentTools.request("read", arguments: ["lines": [3, 9], "path": "notes/a.md"]).get()
        #expect(read.op == .read && read.lines == [3, 9] && read.path == "notes/a.md")
        let search = try DocumentTools.request("search", arguments: ["query": "Ann", "folder": true]).get()
        #expect(search.op == .search && search.query == "Ann" && search.folder == true)
        #expect((try? DocumentTools.request("search", arguments: ["query": ""]).get()) == nil)
        #expect((try? DocumentTools.request("search", arguments: ["query": "a", "folder": "yes"]).get()) == nil)
        #expect((try? DocumentTools.request("delete_file", arguments: [:]).get()) == nil)
        #expect((try? DocumentTools.request("read", arguments: ["lines": [1.9, 3.2]]).get()) == nil, "fractions are not truncated")
        #expect((try? DocumentTools.request("read", arguments: ["lines": [true, 3]]).get()) == nil, "booleans are not numbers")
        #expect((try? DocumentTools.request("read", arguments: ["lines": [5, 2]]).get()) == nil)
        #expect((try? DocumentTools.request("propose_patch", arguments: ["summary": "s", "edits": [["find": "a", "replace": "b"]], "base_revision": 7]).get()) == nil)
    }

    @Test func resultsAreTheSameTextEverywhere() {
        var response = AgentResponse()
        response.text = "a\r\nb\n"
        response.firstLine = 7
        response.revision = "r1"
        #expect(DocumentTools.result(of: response, for: .read) == "revision: r1\n7\ta\n8\tb")
        #expect(DocumentTools.result(of: AgentResponse(error: "nope"), for: .search) == "nope")
    }
}

// In the same serialized suite: the URL stub is shared state.
extension AIChatRequestTests {
    /// A read call is reported as a tool call; continuing sends only its result, no new user text.
    @Test func readCallsContinueTheTurn() async {
        URLProtocol.registerClass(StubProtocol.self)
        defer { URLProtocol.unregisterClass(StubProtocol.self) }
        StubProtocol.requests = []
        StubProtocol.bodies = []
        StubProtocol.replies = [
            (200, sse([["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": "toolu_r", "name": "read", "input": [:]]],
                       ["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": #"{"lines":[1,5]}"#]],
                       ["type": "content_block_stop", "index": 0],
                       ["type": "message_delta", "delta": ["stop_reason": "tool_use"]]])),
            (200, sse([["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
                       ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Read it"]],
                       ["type": "content_block_stop", "index": 0],
                       ["type": "message_delta", "delta": ["stop_reason": "end_turn"]]])),
        ]
        let chat = AIChat(endpoint: AIEndpoint(kind: .anthropic, baseURL: "https://stub.test", model: "claude-opus-5-5"), apiKey: "sk-test", system: "sys")
        var events: [AIChat.Event] = []
        chat.onEvent = { events.append($0) }
        chat.send("what is in it?")
        while chat.isStreaming { try? await Task.sleep(nanoseconds: 5_000_000) }
        #expect(events.contains { if case let .toolCall(id, request) = $0 { id == "toolu_r" && request.op == .read && request.lines == [1, 5] } else { false } })
        #expect(chat.awaitsResult("toolu_r"))
        let tools = (StubProtocol.bodies[0]["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        #expect(tools == ["read", "search", "propose_patch", "get_appearance", "set_appearance"])
        chat.send(nil, results: ["toolu_r": "1\tHello"])
        while chat.isStreaming { try? await Task.sleep(nanoseconds: 5_000_000) }
        let messages = StubProtocol.bodies[1]["messages"] as? [[String: Any]] ?? []
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let last = messages.last?["content"] as? [[String: Any]] ?? []
        #expect(last.count == 1 && last.first?["type"] as? String == "tool_result" && last.first?["content"] as? String == "1\tHello")
        #expect(events.contains { if case .completed(kept: true) = $0 { true } else { false } })
    }
}

extension AIChatRequestTests {
    /// The app may answer a read while the answer is still streaming (the current document is read
    /// at once): that result is kept and sent on, not replaced by "not decided yet".
    @Test func resultsGivenWhileStreamingAreKept() async {
        URLProtocol.registerClass(StubProtocol.self)
        defer { URLProtocol.unregisterClass(StubProtocol.self) }
        StubProtocol.requests = []
        StubProtocol.bodies = []
        StubProtocol.replies = [
            (200, sse([["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": "toolu_s", "name": "read", "input": [:]]],
                       ["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": "{}"]],
                       ["type": "content_block_stop", "index": 0],
                       ["type": "message_delta", "delta": ["stop_reason": "tool_use"]]])),
            (200, sse([["type": "message_delta", "delta": ["stop_reason": "end_turn"]]])),
        ]
        let chat = AIChat(endpoint: AIEndpoint(kind: .anthropic, baseURL: "https://stub.test", model: "claude-opus-5-5"), apiKey: "sk-test", system: "sys")
        chat.onEvent = { event in if case let .toolCall(id, _) = event { chat.answer(id, with: "1\tNow") } }
        chat.send("read it")
        while chat.isStreaming { try? await Task.sleep(nanoseconds: 5_000_000) }
        #expect(chat.unansweredCalls.isEmpty)
        chat.send(nil)
        while chat.isStreaming { try? await Task.sleep(nanoseconds: 5_000_000) }
        let last = (StubProtocol.bodies[1]["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]] ?? []
        #expect(last.first?["content"] as? String == "1\tNow")
    }
}

/// Listing an endpoint's models for the model field (design §10): the key goes only to its own
/// endpoint in that provider's header, and only chat models are offered, newest first.
@Suite struct AIModelsTests {
    @Test func requestsCarryTheKeyTheProviderExpects() throws {
        let anthropic = try AIModels.request(.preset(.anthropic), apiKey: "k")
        #expect(anthropic.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=100")
        #expect(anthropic.value(forHTTPHeaderField: "x-api-key") == "k" && anthropic.value(forHTTPHeaderField: "anthropic-version") != nil)
        let openAI = try AIModels.request(.preset(.openAI), apiKey: "k")
        #expect(openAI.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(openAI.value(forHTTPHeaderField: "authorization") == "Bearer k")
        let local = try AIModels.request(.preset(.compatible), apiKey: nil)
        #expect(local.url?.absoluteString == "http://localhost:11434/v1/models" && local.value(forHTTPHeaderField: "authorization") == nil)
        #expect(throws: (any Error).self) { try AIModels.request(AIEndpoint(kind: .openAI, baseURL: "http://example.com/v1", model: ""), apiKey: "k") }
    }

    @Test func parsesBothFormatsNewestFirst() {
        let openAI = #"{"data":[{"id":"gpt-old","created":100},{"id":"text-embedding-3","created":300},{"id":"gpt-new","created":200},{"id":"tts-1","created":250}]}"#
        #expect(AIModels.parse(Data(openAI.utf8)) == ["gpt-new", "gpt-old"])
        let anthropic = #"{"data":[{"id":"claude-b","created_at":"2026-05-01T00:00:00Z"},{"id":"claude-a","created_at":"2026-09-01T00:00:00Z"}],"has_more":false}"#
        #expect(AIModels.parse(Data(anthropic.utf8)) == ["claude-a", "claude-b"])
        let undated = #"{"data":[{"id":"llama3"},{"id":"qwen3"}]}"#
        #expect(AIModels.parse(Data(undated.utf8)) == ["llama3", "qwen3"], "the server's order stands")
        #expect(AIModels.parse(Data("not json".utf8)).isEmpty)
    }
}
