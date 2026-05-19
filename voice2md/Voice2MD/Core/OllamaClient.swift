import Foundation

enum OllamaError: Error, LocalizedError {
    case missingEndpoint
    case missingModel
    case invalidEndpoint(String)
    case notRunning
    case httpError(Int, body: String)
    case malformedResponse(String)
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .missingEndpoint: return "Ollama endpoint is empty. Set it in Settings → AI."
        case .missingModel: return "Ollama model name is empty. Set it in Settings → AI."
        case .invalidEndpoint(let s): return "Ollama endpoint is not a valid URL: \(s)"
        case .notRunning: return "Could not reach Ollama. Is `ollama serve` running?"
        case .httpError(let status, let body):
            return "Ollama returned HTTP \(status): \(body.prefix(200))"
        case .malformedResponse(let msg): return "Malformed Ollama response: \(msg)"
        case .invalidJSON(let msg): return "Could not parse extraction JSON: \(msg)"
        }
    }
}

final class OllamaClient: Sendable, AIExtractor {
    private let endpoint: String
    private let model: String
    private let session: URLSession

    init(endpoint: String, model: String, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.model = model
        self.session = session
    }

    func testConnection() async throws {
        try validateConfig()
        let url = try makeBaseURL().appending(path: "/api/tags")
        var req = URLRequest(url: url)
        req.timeoutInterval = 5

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw OllamaError.malformedResponse("non-HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                throw OllamaError.httpError(http.statusCode, body: bodyText)
            }
        } catch let urlError as URLError where Self.isUnreachable(urlError) {
            throw OllamaError.notRunning
        }
    }

    func extract(transcript: String, systemPrompt: String) async throws -> ExtractionResult {
        try validateConfig()
        AppLog.claude.info("ollama: extract \(transcript.count, privacy: .public) chars via \(self.model, privacy: .public)")

        let firstReply = try await postChat(
            body: makeExtractionBody(systemPrompt: systemPrompt, userText: transcript)
        )
        if let parsed = ExtractionResult.tryParse(firstReply) {
            return parsed
        }

        AppLog.claude.warning("ollama: first parse failed; requesting JSON repair")
        let repairText = """
            The previous response did not parse as valid JSON for our schema. Please return ONLY the corrected JSON object matching the schema — no prose, no code fences, no preamble.

            Previous response:
            \(firstReply)
            """
        let secondReply = try await postChat(
            body: makeExtractionBody(systemPrompt: systemPrompt, userText: repairText)
        )
        if let parsed = ExtractionResult.tryParse(secondReply) {
            return parsed
        }
        throw OllamaError.invalidJSON("repair also failed; first 200 chars: \(String(firstReply.prefix(200)))")
    }

    func listAvailableModels() async throws -> [String] {
        try validateConfig()
        let url = try makeBaseURL().appending(path: "/api/tags")
        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw OllamaError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0,
                                            body: String(data: data, encoding: .utf8) ?? "")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else {
                return []
            }
            return models
                .compactMap { $0["name"] as? String }
                .sorted()
        } catch let urlError as URLError where Self.isUnreachable(urlError) {
            throw OllamaError.notRunning
        }
    }

    private func validateConfig() throws {
        guard !endpoint.isEmpty else { throw OllamaError.missingEndpoint }
        guard !model.isEmpty else { throw OllamaError.missingModel }
    }

    private func makeExtractionBody(systemPrompt: String, userText: String) -> [String: Any] {
        return [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText]
            ],
            "stream": false,
            "format": "json",
            "options": [
                "temperature": 0,
                "num_ctx": 8192
            ]
        ]
    }

    private func postChat(body: [String: Any]) async throws -> String {
        let url = try makeBaseURL().appending(path: "/api/chat")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 600

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw OllamaError.malformedResponse("non-HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                throw OllamaError.httpError(http.statusCode, body: bodyText)
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw OllamaError.malformedResponse("non-object JSON")
            }
            let message = json["message"] as? [String: Any]
            return (message?["content"] as? String) ?? ""
        } catch let urlError as URLError where Self.isUnreachable(urlError) {
            throw OllamaError.notRunning
        }
    }

    private func makeBaseURL() throws -> URL {
        guard let url = URL(string: endpoint), url.scheme != nil, url.host != nil else {
            throw OllamaError.invalidEndpoint(endpoint)
        }
        return url
    }

    private static func isUnreachable(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotConnectToHost, .timedOut, .cannotFindHost, .networkConnectionLost:
            return true
        default:
            return false
        }
    }
}
