import Foundation

/// Headless fallback scorer using OpenRouter's OpenAI-compatible chat API.
/// Only used when config.scorer.provider == "openrouter"; the default path is
/// in-session scoring on the user's Claude subscription. Curation-only network
/// dependency, opt-in.
public struct OpenRouterScorer: Sendable {
    let model: String
    let apiKey: String
    let http: Http
    let prompt: String
    let promptHash: String

    public init(model: String, apiKey: String, http: Http, prompt: String) {
        self.model = model
        self.apiKey = apiKey
        self.http = http
        self.prompt = prompt
        self.promptHash = Pipeline.promptHash(prompt)
    }

    public func score(id: String, metadata: String, thumbnailJPEG: Data) async throws -> ScoreResult {
        let dataURL = "data:image/jpeg;base64," + thumbnailJPEG.base64EncodedString()
        let userText = prompt.replacingOccurrences(of: "{metadata}", with: metadata)
        let body: [String: Any] = [
            "model": model,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image_url", "image_url": ["url": dataURL]],
                    ["type": "text", "text": userText],
                ],
            ]],
            "response_format": ["type": "json_object"],
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let resp = try await http.post(
            URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
            body: payload,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Content-Type": "application/json",
            ],
            cache: false
        )
        guard let root = try JSONSerialization.jsonObject(with: resp) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let contentData = content.data(using: .utf8),
              let verdict = try JSONSerialization.jsonObject(with: contentData) as? [String: Any] else {
            throw HttpError(status: 0, url: "openrouter", bodyPrefix: "unparseable scorer response for \(id)")
        }
        let score = (verdict["score"] as? Double) ?? Double(verdict["score"] as? Int ?? 0)
        let caption = (verdict["caption"] as? String) ?? ""
        let defects = (verdict["defects"] as? [String]) ?? []
        return ScoreResult(id: id, promptHash: promptHash, score: score, caption: caption,
                           defects: defects, scoredBy: "openrouter:\(model)")
    }
}
