import XCTest
@testable import Voice2MD

final class AzureOpenAIClientTests: XCTestCase {

    private func makeClient(
        apiKey: String = "azure-key",
        endpoint: String = "https://my-resource.openai.azure.com",
        deployment: String = "gpt-4o",
        apiVersion: String = "2024-08-01-preview",
        responder: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)
    ) -> AzureOpenAIClient {
        MockURLProtocol.responder = responder
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return AzureOpenAIClient(
            apiKey: apiKey,
            endpoint: endpoint,
            deployment: deployment,
            apiVersion: apiVersion,
            session: session
        )
    }

    override func tearDown() async throws {
        MockURLProtocol.responder = nil
    }

    func testTestConnectionURLAndHeaders() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "my-resource.openai.azure.com")
            XCTAssertEqual(request.url?.path, "/openai/deployments/gpt-4o/chat/completions")
            XCTAssertEqual(
                request.url?.query?.contains("api-version=2024-08-01-preview"),
                true
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "azure-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"), "azure should not send anthropic-style header")
            return Self.makeChoicesResponse("pong", url: request.url!)
        }
        try await client.testConnection()
    }

    func testTestConnectionMissingApiKey() async {
        let client = makeClient(apiKey: "") { _ in
            XCTFail("should not hit the network")
            return (HTTPURLResponse(), Data())
        }
        do {
            try await client.testConnection()
            XCTFail("expected throw")
        } catch AzureError.missingApiKey {
            // ok
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testTestConnectionMissingDeployment() async {
        let client = makeClient(deployment: "") { _ in
            XCTFail("should not hit the network")
            return (HTTPURLResponse(), Data())
        }
        do {
            try await client.testConnection()
            XCTFail("expected throw")
        } catch AzureError.missingDeployment {
            // ok
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testTestConnectionInvalidEndpoint() async {
        let client = makeClient(endpoint: "not-a-url") { _ in
            XCTFail("should not hit the network")
            return (HTTPURLResponse(), Data())
        }
        do {
            try await client.testConnection()
            XCTFail("expected throw")
        } catch AzureError.invalidEndpoint {
            // ok
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testExtractHappyPath() async throws {
        let json = """
        {
          "title": "Test",
          "summary": "ok",
          "key_ideas": ["a"],
          "topics": ["t"],
          "action_items": [{"task":"do","owner":null,"due":null}],
          "entities": {"people":[],"places":[],"orgs":[]},
          "cleaned_transcript": "ok"
        }
        """
        let client = makeClient { request in
            self.verifyExtractRequest(request: request)
            return Self.makeChoicesResponse(json, url: request.url!)
        }
        let result = try await client.extract(transcript: "transcript", systemPrompt: "system")
        XCTAssertEqual(result.title, "Test")
        XCTAssertEqual(result.actionItems.first?.task, "do")
    }

    func testExtractRepairsMalformedFirstResponse() async throws {
        let attempts = ConcurrentCounter()
        let valid = """
        {"title":"R","summary":"","key_ideas":[],"topics":[],"action_items":[],"entities":{"people":[],"places":[],"orgs":[]},"cleaned_transcript":""}
        """
        let client = makeClient { request in
            let n = attempts.increment()
            if n == 1 {
                return Self.makeChoicesResponse("not json", url: request.url!)
            } else {
                return Self.makeChoicesResponse(valid, url: request.url!)
            }
        }
        let result = try await client.extract(transcript: "x", systemPrompt: "y")
        XCTAssertEqual(result.title, "R")
        XCTAssertEqual(attempts.current, 2)
    }

    func testRetryOn500() async throws {
        let attempts = ConcurrentCounter()
        let valid = """
        {"title":"OK","summary":"","key_ideas":[],"topics":[],"action_items":[],"entities":{"people":[],"places":[],"orgs":[]},"cleaned_transcript":""}
        """
        let client = makeClient { request in
            let n = attempts.increment()
            if n == 1 {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            } else {
                return Self.makeChoicesResponse(valid, url: request.url!)
            }
        }
        let result = try await client.extract(transcript: "x", systemPrompt: "y")
        XCTAssertEqual(result.title, "OK")
        XCTAssertEqual(attempts.current, 2)
    }

    func test401IsHttpError() async {
        let client = makeClient { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data(#"{"error":"invalid api key"}"#.utf8)
            )
        }
        do {
            try await client.testConnection()
            XCTFail("expected throw")
        } catch AzureError.httpError(let status, _) {
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    private func verifyExtractRequest(request: URLRequest) {
        guard let bodyData = request.httpBody ?? Self.bodyFromStream(request),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            XCTFail("could not decode request body")
            return
        }
        let messages = json["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?[0]["role"] as? String, "system")
        XCTAssertEqual(messages?[1]["role"] as? String, "user")
        let format = json["response_format"] as? [String: String]
        XCTAssertEqual(format?["type"], "json_object")
        XCTAssertEqual((json["temperature"] as? NSNumber)?.intValue, 0)
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

    private static func makeChoicesResponse(_ content: String, url: URL) -> (HTTPURLResponse, Data) {
        let envelope: [String: Any] = [
            "choices": [
                ["message": ["role": "assistant", "content": content], "finish_reason": "stop"]
            ],
            "usage": ["prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15]
        ]
        let data = try! JSONSerialization.data(withJSONObject: envelope)
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (resp, data)
    }
}
