import Foundation

enum AzureError: Error, LocalizedError {
    case missingApiKey
    case missingEndpoint
    case missingDeployment
    case invalidEndpoint(String)
    case httpError(Int, body: String)
    case malformedResponse(String)
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .missingApiKey: return "Azure OpenAI API key is empty. Set it in Settings → AI."
        case .missingEndpoint: return "Azure OpenAI endpoint is empty. Set it in Settings → AI."
        case .missingDeployment: return "Azure OpenAI deployment name is empty. Set it in Settings → AI."
        case .invalidEndpoint(let s): return "Azure OpenAI endpoint is not a valid URL: \(s)"
        case .httpError(let status, let body):
            return "Azure OpenAI returned HTTP \(status): \(body.prefix(200))"
        case .malformedResponse(let msg): return "Malformed Azure OpenAI response: \(msg)"
        case .invalidJSON(let msg): return "Could not parse extraction JSON: \(msg)"
        }
    }
}

final class AzureOpenAIClient: Sendable, AIExtractor {
    private let apiKey: String
    private let endpoint: String
    private let deployment: String
    private let apiVersion: String
    private let session: URLSession

    init(
        apiKey: String,
        endpoint: String,
        deployment: String,
        apiVersion: String = AppConfig.defaultAzureApiVersion,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.deployment = deployment
        self.apiVersion = apiVersion.isEmpty ? AppConfig.defaultAzureApiVersion : apiVersion
        self.session = session
    }

    func testConnection() async throws {
        try validateConfig()
        let body: [String: Any] = [
            "messages": [["role": "user", "content": "ping"]],
            "max_tokens": 1
        ]
        _ = try await postChat(body: body)
    }

    func extract(transcript: String, systemPrompt: String) async throws -> ExtractionResult {
        try validateConfig()
        AppLog.claude.info("azure: extract \(transcript.count, privacy: .public) chars via \(self.deployment, privacy: .public)")

        let firstReply = try await postChatWithRetry(
            body: makeExtractionBody(systemPrompt: systemPrompt, userText: transcript)
        )
        if let parsed = ExtractionResult.tryParse(firstReply) {
            return parsed
        }

        AppLog.claude.warning("azure: first parse failed; requesting JSON repair")
        let repairText = """
            The previous response did not parse as valid JSON for our schema. Please return ONLY the corrected JSON object matching the schema — no prose, no code fences, no preamble.

            Previous response:
            \(firstReply)
            """
        let secondReply = try await postChatWithRetry(
            body: makeExtractionBody(systemPrompt: systemPrompt, userText: repairText)
        )
        if let parsed = ExtractionResult.tryParse(secondReply) {
            return parsed
        }
        throw AzureError.invalidJSON("repair also failed; first 200 chars: \(String(firstReply.prefix(200)))")
    }

    private func validateConfig() throws {
        guard !apiKey.isEmpty else { throw AzureError.missingApiKey }
        guard !endpoint.isEmpty else { throw AzureError.missingEndpoint }
        guard !deployment.isEmpty else { throw AzureError.missingDeployment }
    }

    private func makeExtractionBody(systemPrompt: String, userText: String) -> [String: Any] {
        return [
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText]
            ],
            "max_tokens": 4096,
            "temperature": 0,
            "response_format": ["type": "json_object"]
        ]
    }

    private func postChatWithRetry(body: [String: Any]) async throws -> String {
        do {
            return try await postChat(body: body)
        } catch AzureError.httpError(let status, _) where status == 429 || (500..<600).contains(status) {
            AppLog.claude.warning("azure: retry after HTTP \(status, privacy: .public)")
            try await Task.sleep(for: .seconds(2))
            return try await postChat(body: body)
        }
    }

    private func postChat(body: [String: Any]) async throws -> String {
        let url = try makeURL()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AzureError.malformedResponse("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw AzureError.httpError(http.statusCode, body: bodyText)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AzureError.malformedResponse("non-object JSON")
        }
        let choices = (json["choices"] as? [[String: Any]]) ?? []
        let message = choices.first?["message"] as? [String: Any]
        return (message?["content"] as? String) ?? ""
    }

    private func makeURL() throws -> URL {
        guard let base = URL(string: endpoint),
              base.scheme != nil,
              base.host != nil else {
            throw AzureError.invalidEndpoint(endpoint)
        }
        let path = "/openai/deployments/\(deployment)/chat/completions"
        return base
            .appending(path: path)
            .appending(queryItems: [URLQueryItem(name: "api-version", value: apiVersion)])
    }
}
