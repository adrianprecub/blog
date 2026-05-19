import XCTest
@testable import Voice2MD

/// Hits the user's local Ollama if it's running. Skipped otherwise.
final class OllamaIntegrationTests: XCTestCase {
    private let endpoint = "http://localhost:11434"

    private func ollamaIsRunning() async -> Bool {
        var req = URLRequest(url: URL(string: "\(endpoint)/api/tags")!)
        req.timeoutInterval = 2
        return ((try? await URLSession.shared.data(for: req)) != nil)
    }

    private func pickModel() async -> String? {
        let probe = OllamaClient(endpoint: endpoint, model: "_probe_")
        guard let names = try? await probe.listAvailableModels() else { return nil }
        let preferred = [
            "qwen2.5:14b", "qwen3:14b",
            "llama3.1:8b", "llama3:8b", "llama3:latest",
            "gemma3:27b", "gemma3:12b",
            "qwen3:32b",
            "qwen2.5:7b", "mistral:7b", "gemma3:7b"
        ]
        for p in preferred where names.contains(p) { return p }
        return names.first { name in
            !name.contains("embed") && !name.contains("cloud")
        }
    }

    func testExtractAgainstLocalOllama() async throws {
        let running = await ollamaIsRunning()
        try XCTSkipUnless(running, "Ollama not running on \(endpoint); skipping")
        guard let model = await pickModel() else {
            throw XCTSkip("no usable Ollama model installed")
        }

        let systemPrompt = try ClaudeClient.loadSystemPrompt()
        let client = OllamaClient(endpoint: endpoint, model: model)
        let transcript = """
            Hello, this is a quick test memo. I need to draft an RFC for the new caching layer by Friday — \
            Alex will own that. We also discussed hiring two more senior engineers next quarter at Acme Corp.
            """

        let result = try await client.extract(transcript: transcript, systemPrompt: systemPrompt)
        XCTAssertFalse(result.title.isEmpty, "title should be non-empty (got \(result.title))")
        XCTAssertFalse(result.cleanedTranscript.isEmpty, "cleaned_transcript should be non-empty")
    }
}
