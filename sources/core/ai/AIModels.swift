import Foundation

/// The models an endpoint offers, for the model field in Settings → Agents (design §10): Anthropic's
/// `GET /v1/models`, and `GET {base}/models` for OpenAI and compatible servers (Ollama, LM Studio and
/// the like serve it under their `/v1` base). The key goes only to its own endpoint, as for chats;
/// a local server is asked without one.
public enum AIModels {
    public static func request(_ endpoint: AIEndpoint, apiKey: String?) throws -> URLRequest {
        let base = endpoint.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let path = endpoint.kind == .anthropic ? "/v1/models?limit=100" : "/models"
        guard let url = URL(string: base + path),
              url.scheme == "https" || url.host == "localhost" || url.host == "127.0.0.1" else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let apiKey, !apiKey.isEmpty {
            if endpoint.kind == .anthropic {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            } else {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
            }
        }
        if endpoint.kind == .anthropic { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        return request
    }

    /// Model ids from either format (`{"data": [{"id": …, "created" | "created_at": …}]}`), newest
    /// first, without the models no chat can use (embeddings, speech, images, moderation).
    public static func parse(_ data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["data"] as? [[String: Any]] else { return [] }
        let skipped = ["embed", "tts", "whisper", "transcribe", "dall-e", "image", "moderation", "audio", "realtime", "search"]
        var models: [(id: String, created: Double)] = []
        for (i, item) in items.enumerated() {
            guard let id = item["id"] as? String, !skipped.contains(where: { id.lowercased().contains($0) }) else { continue }
            // Without dates, the server's order stands (Anthropic lists newest first).
            var created = -Double(i)
            if let seconds = item["created"] as? Double { created = seconds }
            if let date = (item["created_at"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) }) { created = date.timeIntervalSince1970 }
            models.append((id, created))
        }
        return models.sorted { $0.created > $1.created }.map(\.id)
    }

    public static func fetch(_ endpoint: AIEndpoint, apiKey: String?) async throws -> [String] {
        let (data, response) = try await URLSession.shared.data(for: try request(endpoint, apiKey: apiKey), delegate: SameHostRedirects())
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.init(rawValue: http.statusCode), userInfo: [NSLocalizedDescriptionKey: HTTPURLResponse.localizedString(forStatusCode: http.statusCode)])
        }
        return parse(data)
    }
}
