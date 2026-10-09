import Foundation

/// The built-in AI's model connection (design §10): direct API calls to Anthropic, OpenAI, or an
/// OpenAI-compatible endpoint, streamed and cancellable. The model gets the same document tools as
/// external agents (design §21.6): `read` and `search` are answered by the caller and the turn
/// continues; `propose_patch` becomes an `EditProposal` the user reviews, never a write. History is
/// append-only and lives only as long as the chat (no request bodies on disk).
public struct AIEndpoint: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case anthropic, openAI, compatible }
    public var kind: Kind
    public var baseURL: String
    public var model: String
    /// Compatible endpoints declare tool calls (design §10); without them the chat cannot propose edits.
    public var supportsTools: Bool

    public init(kind: Kind, baseURL: String, model: String, supportsTools: Bool = true) {
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.supportsTools = supportsTools
    }

    public static func preset(_ kind: Kind) -> AIEndpoint {
        switch kind {
        case .anthropic: AIEndpoint(kind: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-opus-5-5")
        case .openAI: AIEndpoint(kind: .openAI, baseURL: "https://api.openai.com/v1", model: "")
        case .compatible: AIEndpoint(kind: .compatible, baseURL: "http://localhost:11434/v1", model: "", supportsTools: false)
        }
    }

    /// The API key is bound to this (design §10): it is never sent anywhere else.
    public var keyAccount: String { kind.rawValue + " " + baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }

    public var host: String? { URL(string: baseURL)?.host?.lowercased() }

    /// Anthropic and OpenAI need a key; compatible servers (Ollama, LM Studio) often run without
    /// one and get it only when one is saved.
    public var needsKey: Bool { kind == .anthropic || kind == .openAI }
}

@MainActor
public final class AIChat {
    public enum Event {
        case text(String)
        /// A read-only document tool (`read`, `search`); answer it through `send(nil, results:)`.
        case toolCall(id: String, request: AgentRequest)
        case proposal(id: String, summary: String, edits: [ProposedEdit], baseRevision: String?)
        /// An appearance tool (`get_appearance`, `set_appearance`) with its JSON arguments; the
        /// app runs it and answers through `answer(_:with:)`.
        case appearance(id: String, name: String, arguments: String)
        /// A tool call that was refused; the model is told why with the next request.
        case invalidToolCall(String)
        case finished(stopReason: String?)
        case failed(String)
        /// The request is over and the chat can send again. `kept` is false when the turn was taken
        /// back (nothing arrived, a refusal, a failed request): it was never part of the chat.
        case completed(kept: Bool)
    }

    public let endpoint: AIEndpoint
    private let apiKey: String
    public var system: String
    public var onEvent: ((Event) -> Void)?
    /// Provider-shaped messages, appended only (thinking blocks are echoed back unchanged).
    private(set) var history: [[String: Any]] = []
    /// Tool calls of the last answer still waiting for their results.
    private var openCalls: [String] = []
    /// Results for open calls, kept until a request carrying them succeeds: a failed request must
    /// not turn a finished read into "not decided yet". Refused calls get their reason here.
    private var answers: [String: String] = [:]
    private var task: Task<Void, Never>?
    public var isStreaming: Bool { task != nil }

    public init(endpoint: AIEndpoint, apiKey: String, system: String) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.system = system
    }

    /// The document tools the built-in AI has: no `get_context`, since every message carries the
    /// context card. The appearance tools come after them.
    static let tools: [DocumentTools.Name] = [.read, .search, .proposePatch]

    /// Whether the last answer's tool call `id` still waits for its result.
    public func awaitsResult(_ id: String) -> Bool { openCalls.contains(id) }

    /// Tool calls of the last answer that have no result yet (a running read, an undecided proposal).
    public var unansweredCalls: [String] { openCalls.filter { answers[$0] == nil } }

    /// The result of tool call `id`, sent with the next request and kept until one succeeds.
    public func answer(_ id: String, with result: String) {
        guard openCalls.contains(id) else { return }
        answers[id] = result
    }

    /// Send the user's turn, or with `text` nil continue the answer after its tool calls.
    /// `results` adds to the answers given through `answer(_:with:)`; a call still without one
    /// when the user moves on is reported as undecided.
    public func send(_ text: String?, results: [String: String] = [:]) {
        guard task == nil, text != nil || !openCalls.isEmpty else { return }
        self.answers.merge(results) { _, new in new }
        let answers = openCalls.map { ($0, self.answers[$0] ?? "The user has not decided on this proposal yet.") }
        let turnStart = history.count, calls = openCalls
        openCalls = []
        switch endpoint.kind {
        case .anthropic:
            var content: [[String: Any]] = answers.map { ["type": "tool_result", "tool_use_id": $0.0, "content": $0.1] }
            if let text { content.append(["type": "text", "text": text]) }
            history.append(["role": "user", "content": content])
        case .openAI, .compatible:
            for (id, result) in answers { history.append(["role": "tool", "tool_call_id": id, "content": result]) }
            if let text { history.append(["role": "user", "content": text]) }
        }
        let request: URLRequest
        do { request = try makeRequest() } catch {
            history.removeSubrange(turnStart...)
            openCalls = calls
            onEvent?(.failed(error.localizedDescription))
            onEvent?(.completed(kept: false))
            return
        }
        task = Task { [weak self] in
            guard let self else { return }
            // Nothing came back (network error, rejected request): the turn is taken back, so the
            // next message does not follow an unanswered one and the tool results are sent again.
            let kept = await self.stream(request)
            if kept {
                for id in calls { self.answers[id] = nil }
            } else {
                self.history.removeSubrange(turnStart...)
                self.openCalls = calls
            }
            self.task = nil
            self.onEvent?(.completed(kept: kept))
        }
    }

    public func cancel() {
        task?.cancel()
    }

    // MARK: Requests

    private func makeRequest() throws -> URLRequest {
        let base = endpoint.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let path = endpoint.kind == .anthropic ? "/v1/messages" : "/chat/completions"
        guard let url = URL(string: base + path), url.scheme == "https" || url.host == "localhost" || url.host == "127.0.0.1" else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: [String: Any] = ["model": endpoint.model, "stream": true]
        switch endpoint.kind {
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body["max_tokens"] = 64000
            body["system"] = system
            body["messages"] = history
            body["cache_control"] = ["type": "ephemeral"]
            body["tools"] = Self.tools.map { name in
                let (description, schema) = DocumentTools.definition(name, session: false)
                return ["name": name.rawValue, "description": description, "input_schema": schema, "eager_input_streaming": true] as [String: Any]
            } + AppearanceTools.names.map { name in
                let (description, schema) = AppearanceTools.definition(name)
                return ["name": name, "description": description, "input_schema": schema, "eager_input_streaming": true] as [String: Any]
            }
            let current = ["claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5", "claude-fable-5-1"].contains(endpoint.model)
            if current { body["output_config"] = ["effort": "medium"] }
            // A safety decline on the first-party API is retried on a fallback model server-side.
            if current, endpoint.host == "api.anthropic.com" {
                request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }
        case .openAI, .compatible:
            if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization") }
            body["messages"] = [["role": "system", "content": system]] + history
            if endpoint.supportsTools {
                body["tools"] = Self.tools.map { name in
                    let (description, schema) = DocumentTools.definition(name, session: false)
                    return ["type": "function", "function": ["name": name.rawValue, "description": description, "parameters": schema]] as [String: Any]
                } + AppearanceTools.names.map { name in
                    let (description, schema) = AppearanceTools.definition(name)
                    return ["type": "function", "function": ["name": name, "description": description, "parameters": schema]] as [String: Any]
                }
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: Streaming

    /// False when no answer arrived, so the caller takes the turn back.
    private func stream(_ request: URLRequest) async -> Bool {
        var parser = endpoint.kind == .anthropic ? StreamParser.anthropic() : StreamParser.openAI()
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request, delegate: SameHostRedirects())
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > 64 << 10 { break }
                }
                onEvent?(.failed(Self.apiError(status: http.statusCode, body: data)))
                return false
            }
            for try await line in bytes.lines {
                try Task.checkCancellation()
                for event in parser.feed(line) { deliver(event) }
            }
        } catch is CancellationError {
            onEvent?(.finished(stopReason: "cancelled"))
        } catch let error as URLError where error.code == .cancelled {
            onEvent?(.finished(stopReason: "cancelled"))
        } catch {
            onEvent?(.failed(error.localizedDescription))
        }
        // A declined request leaves no turn behind: its partial answer is discarded with the question.
        if parser.stopReason == "refusal" { return false }
        // Whatever arrived becomes the assistant turn, so the history stays valid after a cancel.
        guard let message = parser.assistantMessage() else { return false }
        history.append(message)
        openCalls = parser.toolCallIDs
        return true
    }

    private func deliver(_ event: StreamParser.Event) {
        switch event {
        case let .text(t): onEvent?(.text(t))
        case let .toolCall(id, name, json):
            // Strict parse and schema check: eager streaming does not validate tool input.
            let object = json.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if AppearanceTools.names.contains(name) {
                guard object != nil else {
                    answers[id] = "Refused: the tool input was not a JSON object."
                    onEvent?(.invalidToolCall("The tool input was not a JSON object."))
                    return
                }
                openCalls.append(id)
                onEvent?(.appearance(id: id, name: name, arguments: json))
                return
            }
            let parsed = object.map { DocumentTools.request(name, arguments: $0) } ?? .failure(DocumentTools.ToolError("The tool input was not a JSON object."))
            switch parsed {
            case let .failure(error):
                answers[id] = "Refused: \(error.message)"
                onEvent?(.invalidToolCall(error.message))
            case let .success(request) where request.op == .propose:
                onEvent?(.proposal(id: id, summary: request.summary ?? "", edits: request.edits ?? [], baseRevision: request.baseRevision))
            case let .success(request) where request.op == .read || request.op == .search:
                // Open before it goes out: the app may answer at once, while the answer streams.
                openCalls.append(id)
                onEvent?(.toolCall(id: id, request: request))
            case .success:
                answers[id] = "Refused: \(name) is not available here."
                onEvent?(.invalidToolCall("\(name) is not available here."))
            }
        case let .stop(reason): onEvent?(.finished(stopReason: reason))
        case let .error(message): onEvent?(.failed(message))
        }
    }

    nonisolated static func apiError(status: Int, body: Data) -> String {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let message = (object?["error"] as? [String: Any])?["message"] as? String ?? String(decoding: body.prefix(400), as: UTF8.self)
        switch status {
        case 401, 403: return "The API key was rejected (\(status)). Check it in Settings → AI."
        case 429: return "Rate limited (429). Try again shortly. \(message)"
        default: return "HTTP \(status): \(message)"
        }
    }
}

/// Redirects to another host are refused: the request carries the API key, which is bound to its
/// endpoint (design §10).
final class SameHostRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.host == task.originalRequest?.url?.host && request.url?.scheme == task.originalRequest?.url?.scheme ? request : nil)
    }
}

/// Server-sent events of the two wire formats, turned into text, tool calls and the assistant message.
struct StreamParser {
    enum Event: Equatable {
        case text(String)
        case toolCall(id: String, name: String, json: String)
        case stop(String?)
        case error(String)
    }

    private let anthropic: Bool
    /// Anthropic content blocks by index, as received (thinking keeps its signature).
    private var blocks: [Int: [String: Any]] = [:]
    private var partialJSON: [Int: String] = [:]
    /// OpenAI: text and tool calls by index.
    private var text = ""
    private var calls: [Int: (id: String, name: String, arguments: String)] = [:]
    private(set) var toolCallIDs: [String] = []
    private(set) var stopReason: String?

    static func anthropic() -> StreamParser { StreamParser(anthropic: true) }
    static func openAI() -> StreamParser { StreamParser(anthropic: false) }

    mutating func feed(_ line: String) -> [Event] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return [] }
        guard let data = payload.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return anthropic ? feedAnthropic(object) : feedOpenAI(object)
    }

    private mutating func feedAnthropic(_ o: [String: Any]) -> [Event] {
        let index = o["index"] as? Int ?? 0
        switch o["type"] as? String {
        case "content_block_start":
            var block = o["content_block"] as? [String: Any] ?? [:]
            // A tool call counts as complete only once its input has streamed to the end
            // (content_block_stop); the empty input of the start event must not stand for it.
            if block["type"] as? String == "tool_use" { block["input"] = nil }
            blocks[index] = block
        case "content_block_delta":
            guard let delta = o["delta"] as? [String: Any] else { return [] }
            switch delta["type"] as? String {
            case "text_delta":
                let t = delta["text"] as? String ?? ""
                append(t, to: "text", at: index)
                return [.text(t)]
            case "input_json_delta":
                partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
            case "thinking_delta":
                append(delta["thinking"] as? String ?? "", to: "thinking", at: index)
            case "signature_delta":
                append(delta["signature"] as? String ?? "", to: "signature", at: index)
            default:
                break
            }
        case "content_block_stop":
            guard let block = blocks[index], block["type"] as? String == "tool_use", let id = block["id"] as? String else { return [] }
            let json = partialJSON[index] ?? "{}"
            blocks[index]?["input"] = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? [String: Any]()
            toolCallIDs.append(id)
            return [.toolCall(id: id, name: block["name"] as? String ?? "", json: json)]
        case "message_delta":
            if let reason = (o["delta"] as? [String: Any])?["stop_reason"] as? String {
                stopReason = reason
                return [.stop(reason)]
            }
        case "error":
            return [.error((o["error"] as? [String: Any])?["message"] as? String ?? "The stream ended with an error.")]
        default:
            break
        }
        return []
    }

    private mutating func append(_ string: String, to key: String, at index: Int) {
        var block = blocks[index] ?? [:]
        block[key] = (block[key] as? String ?? "") + string
        blocks[index] = block
    }

    private mutating func feedOpenAI(_ o: [String: Any]) -> [Event] {
        if let error = o["error"] as? [String: Any] { return [.error(error["message"] as? String ?? "The stream ended with an error.")] }
        guard let choice = (o["choices"] as? [[String: Any]])?.first else { return [] }
        var events: [Event] = []
        if let delta = choice["delta"] as? [String: Any] {
            if let t = delta["content"] as? String, !t.isEmpty {
                text += t
                events.append(.text(t))
            }
            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let i = call["index"] as? Int ?? 0
                var entry = calls[i] ?? ("", "", "")
                if let id = call["id"] as? String { entry.id = id }
                if let f = call["function"] as? [String: Any] {
                    if let name = f["name"] as? String { entry.name += name }
                    entry.arguments += f["arguments"] as? String ?? ""
                }
                calls[i] = entry
            }
        }
        if let reason = choice["finish_reason"] as? String {
            for i in calls.keys.sorted() {
                let c = calls[i]!
                toolCallIDs.append(c.id)
                events.append(.toolCall(id: c.id, name: c.name, json: c.arguments))
            }
            stopReason = reason == "tool_calls" ? "tool_use" : reason
            events.append(.stop(stopReason))
        }
        return events
    }

    /// The assistant turn to append to the history, or nil when nothing arrived.
    func assistantMessage() -> [String: Any]? {
        if anthropic {
            // Blocks cut off by a cancel are dropped: a tool call without its input would need a result,
            // thinking without its signature and empty text are rejected when sent back.
            let content = blocks.keys.sorted().compactMap { blocks[$0] }.filter { block in
                switch block["type"] as? String {
                case "tool_use": block["input"] != nil
                case "thinking": block["signature"] as? String != nil
                case "text": !(block["text"] as? String ?? "").isEmpty
                default: true
                }
            }
            // Thinking alone is no answer: without text or a complete call the turn is dropped.
            guard content.contains(where: { ["text", "tool_use"].contains($0["type"] as? String) }) else { return nil }
            return ["role": "assistant", "content": content]
        }
        let finished = calls.keys.sorted().compactMap { calls[$0] }.filter { toolCallIDs.contains($0.id) }
        guard !text.isEmpty || !finished.isEmpty else { return nil }
        var message: [String: Any] = ["role": "assistant", "content": text.isEmpty ? NSNull() : text]
        if !finished.isEmpty {
            message["tool_calls"] = finished.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] }
        }
        return message
    }
}
