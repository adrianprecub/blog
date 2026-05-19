import XCTest
@testable import Voice2MD

final class OllamaClientTests: XCTestCase {

    private func makeClient(
        endpoint: String = "http://localhost:11434",
        model: String = "llama3.1:8b",
        responder: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)
    ) -> OllamaClient {
        MockURLProtocol.responder = responder
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return OllamaClient(endpoint: endpoint, model: model, session: session)
    }

    override func tearDown() async throws {
        MockURLProtocol.responder = nil
    }

    func testTestConnectionSuccess() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/tags")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"models":[{"name":"llama3.1:8b"}]}"#.utf8)
            )
        }
        try await client.testConnection()
    }

    func testTestConnectionMissingEndpoint() async {
        let client = makeClient(endpoint: "") { _ in
            XCTFail("should not hit network")
            return (HTTPURLResponse(), Data())
        }
        do {
            try await client.testConnection()
            XCTFail("expected throw")
        } catch OllamaError.missingEndpoint {
            // ok
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testTestConnectionMissingModel() async {
        let client = makeClient(model: "") { _ in
            XCTFail("should not hit network")
            return (HTTPURLResponse(), Data())
        }
        do {
            try await client.testConnection()
            XCTFail("expected throw")
        } catch OllamaError.missingModel {
            // ok
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testTestConnectionInvalidEndpoint() async {
        let client = makeClient(endpoint: "not-a-url") { _ in
            XCTFail("should not hit network")
            return (HTTPURLResponse(), Data())
        }
        do {
            try await client.testConnection()
            XCTFail("expected throw")
        } catch OllamaError.invalidEndpoint {
            // ok
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testExtractHappyPath() async throws {
        let json = """
        {
          "title": "Local Test",
          "summary": "ok",
          "key_ideas": [],
          "topics": [],
          "action_items": [],
          "entities": {"people":[],"places":[],"orgs":[]},
          "cleaned_transcript": "ok"
        }
        """
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/chat")
            self.verifyExtractRequest(request: request)
            return Self.makeChatResponse(content: json, url: request.url!)
        }
        let result = try await client.extract(transcript: "x", systemPrompt: "y")
        XCTAssertEqual(result.title, "Local Test")
    }

    func testExtractRepairsMalformedFirstResponse() async throws {
        let attempts = ConcurrentCounter()
        let valid = """
        {"title":"R","summary":"","key_ideas":[],"topics":[],"action_items":[],"entities":{"people":[],"places":[],"orgs":[]},"cleaned_transcript":""}
        """
        let client = makeClient { request in
            let n = attempts.increment()
            if n == 1 {
                return Self.makeChatResponse(content: "not json {oops", url: request.url!)
            } else {
                return Self.makeChatResponse(content: valid, url: request.url!)
            }
        }
        let result = try await client.extract(transcript: "x", systemPrompt: "y")
        XCTAssertEqual(result.title, "R")
        XCTAssertEqual(attempts.current, 2)
    }

    func test500IsHttpError() async {
        let client = makeClient { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data("server boom".utf8)
            )
        }
        do {
            _ = try await client.extract(transcript: "x", systemPrompt: "y")
            XCTFail("expected throw")
        } catch OllamaError.httpError(let status, _) {
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testListAvailableModels() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/tags")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"models":[{"name":"qwen2.5:14b"},{"name":"llama3.1:8b"}]}"#.utf8)
            )
        }
        let names = try await client.listAvailableModels()
        XCTAssertEqual(names, ["llama3.1:8b", "qwen2.5:14b"])
    }

    private func verifyExtractRequest(request: URLRequest) {
        guard let bodyData = request.httpBody ?? Self.bodyFromStream(request),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            XCTFail("could not decode request body")
            return
        }
        XCTAssertEqual(json["model"] as? String, "llama3.1:8b")
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertEqual(json["format"] as? String, "json")
        let opts = json["options"] as? [String: Any]
        XCTAssertEqual((opts?["num_ctx"] as? NSNumber)?.intValue, 8192, "num_ctx must be set so long prompts don't truncate")
        let messages = json["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?[0]["role"] as? String, "system")
        XCTAssertEqual(messages?[1]["role"] as? String, "user")
        XCTAssertEqual((opts?["temperature"] as? NSNumber)?.intValue, 0)
    }

    private static func bodyFromStream(_ request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buf, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data
    }

    private static func makeChatResponse(content: String, url: URL) -> (HTTPURLResponse, Data) {
        let envelope: [String: Any] = [
            "model": "llama3.1:8b",
            "created_at": "2026-05-08T10:00:00Z",
            "message": ["role": "assistant", "content": content],
            "done": true
        ]
        let data = try! JSONSerialization.data(withJSONObject: envelope)
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (resp, data)
    }
}
