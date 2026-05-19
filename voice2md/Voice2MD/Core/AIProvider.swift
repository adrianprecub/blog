import Foundation

enum AIProvider: String, CaseIterable, Identifiable, Sendable {
    case anthropic
    case azureOpenAI = "azure-openai"
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .azureOpenAI: return "Azure OpenAI"
        case .ollama: return "Ollama (local)"
        }
    }

    var shortName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .azureOpenAI: return "Azure"
        case .ollama: return "Ollama"
        }
    }
}

protocol AIExtractor: Sendable {
    func extract(transcript: String, systemPrompt: String) async throws -> ExtractionResult
    func testConnection() async throws
}

extension ExtractionResult {
    static func tryParse(_ text: String) -> ExtractionResult? {
        let cleaned = stripCodeFences(text)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(ExtractionResult.self, from: data)
    }

    private static func stripCodeFences(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let firstNewline = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: firstNewline)...])
            }
            if t.hasSuffix("```") {
                t = String(t.dropLast(3))
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
