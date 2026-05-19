import Foundation

enum ClaudeError: Error, LocalizedError {
    case missingApiKey
    case missingPrompt
    case httpError(Int, body: String)
    case malformedResponse(String)
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .missingApiKey: return "Anthropic API key is empty. Set it in Settings → AI."
        case .missingPrompt: return "Extraction prompt resource is missing from the app bundle."
        case .httpError(let status, let body):
            return "Anthropic returned HTTP \(status): \(body.prefix(200))"
        case .malformedResponse(let msg):
            return "Malformed response: \(msg)"
        case .invalidJSON(let msg):
            return "Could not parse extraction JSON: \(msg)"
        }
    }
}

final class ClaudeClient: Sendable, AIExtractor {
    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let baseURL: URL

    init(
        apiKey: String,
        model: String,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.anthropic.com")!
    ) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.baseURL = baseURL
    }

    static func loadSystemPrompt() throws -> String {
        guard let url = Bundle.main.url(forResource: "extraction.system", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ClaudeError.missingPrompt
        }
        return text
    }

    func testConnection() async throws {
        guard !apiKey.isEmpty else { throw ClaudeError.missingApiKey }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "ping"]]
        ]
        _ = try await postMessages(body: body)
    }

    func extract(transcript: String, systemPrompt: String) async throws -> ExtractionResult {
        guard !apiKey.isEmpty else { throw ClaudeError.missingApiKey }
        AppLog.claude.info("anthropic: extract \(transcript.count, privacy: .public) chars")

        let firstReply = try await callExtraction(
            systemPrompt: systemPrompt,
            userText: transcript
        )
        if let parsed = ExtractionResult.tryParse(firstReply) {
            return parsed
        }

        AppLog.claude.warning("anthropic: first parse failed; requesting JSON repair")
        let repairText = """
            The previous response did not parse as valid JSON for our schema. Please return ONLY the corrected JSON object matching the schema — no prose, no code fences, no preamble.

            Previous response:
            \(firstReply)
            """
        let secondReply = try await callExtraction(
            systemPrompt: systemPrompt,
            userText: repairText
        )
        if let parsed = ExtractionResult.tryParse(secondReply) {
            return parsed
        }
        throw ClaudeError.invalidJSON("repair also failed; first 200 chars: \(String(firstReply.prefix(200)))")
    }

    private func callExtraction(systemPrompt: String, userText: String) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": [
                [
                    "type": "text",
                    "text": systemPrompt,
                    "cache_control": ["type": "ephemeral"]
                ]
            ],
            "messages": [
                ["role": "user", "content": userText]
            ]
        ]
        let response = try await postMessagesWithRetry(body: body)
        return response.text
    }

    private struct AnthropicResponse {
        let text: String
        let cacheCreationInputTokens: Int
        let cacheReadInputTokens: Int
        let inputTokens: Int
        let outputTokens: Int
    }

    private func postMessagesWithRetry(body: [String: Any]) async throws -> AnthropicResponse {
        do {
            return try await postMessages(body: body)
        } catch ClaudeError.httpError(let status, _) where status == 429 || (500..<600).contains(status) {
            AppLog.claude.warning("anthropic: retry after HTTP \(status, privacy: .public)")
            try await Task.sleep(for: .seconds(2))
            return try await postMessages(body: body)
        }
    }

    private func postMessages(body: [String: Any]) async throws -> AnthropicResponse {
        var req = URLRequest(url: baseURL.appending(path: "/v1/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeError.malformedResponse("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw ClaudeError.httpError(http.statusCode, body: bodyText)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.malformedResponse("non-object JSON")
        }
        let content = (json["content"] as? [[String: Any]]) ?? []
        let text = content.compactMap { $0["text"] as? String }.joined()
        let usage = (json["usage"] as? [String: Any]) ?? [:]

        return AnthropicResponse(
            text: text,
            cacheCreationInputTokens: (usage["cache_creation_input_tokens"] as? Int) ?? 0,
            cacheReadInputTokens: (usage["cache_read_input_tokens"] as? Int) ?? 0,
            inputTokens: (usage["input_tokens"] as? Int) ?? 0,
            outputTokens: (usage["output_tokens"] as? Int) ?? 0
        )
    }

    static func tryParse(_ text: String) -> ExtractionResult? {
        ExtractionResult.tryParse(text)
    }
}
