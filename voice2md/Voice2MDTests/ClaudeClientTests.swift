import XCTest
@testable import Voice2MD

final class ClaudeClientTests: XCTestCase {

    private func makeClient(
        apiKey: String = "sk-ant-test",
        model: String = "claude-haiku-4-5",
        responder: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)
    ) -> ClaudeClient {
        MockURLProtocol.responder = responder
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return ClaudeClient(apiKey: apiKey, model: model, session: session)
    }

    override func tearDown() async throws {
        MockURLProtocol.responder = nil
    }

    func testTestConnectionSuccess() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/v1/messages")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"content":[{"type":"text","text":"pong"}],"usage":{"input_tokens":2,"output_tokens":1}}"#.utf8)
            )
        }
        try await client.testConnection()
    }

    func testTestConnectionFailureMissingKey() async {
        let client = ClaudeClient(apiKey: "", model: "claude-haiku-4-5")
        do {
            try await client.testConnection()
            XCTFail("expected throw")
        } catch ClaudeError.missingApiKey {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testTestConnectionHTTP401() async {
        let client = makeClient { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data(#"{"error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
            )
        }
        do {
            try await client.testConnection()
            XCTFail("expected throw")
        } catch ClaudeError.httpError(let status, _) {
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testExtractHappyPath() async throws {
        let json = """
        {
          "title": "Q3 Roadmap Review",
          "summary": "We discussed the Q3 roadmap.",
          "key_ideas": ["ship feature X", "decide on hiring plan"],
          "topics": ["roadmap", "engineering"],
          "action_items": [{"task": "draft RFC", "owner": "Alex", "due": "Friday"}],
          "entities": {"people": ["Alex"], "places": [], "orgs": ["Acme"]},
          "cleaned_transcript": "We discussed the Q3 roadmap. Alex will draft an RFC by Friday."
        }
        """
        let client = makeClient { request in
            self.verifyExtractRequest(request: request, expectedSystemBlock: true)
            return self.makeContentResponse(json)
        }

        let result = try await client.extract(
            transcript: "transcript text",
            systemPrompt: "system prompt"
        )

        XCTAssertEqual(result.title, "Q3 Roadmap Review")
        XCTAssertEqual(result.keyIdeas.count, 2)
        XCTAssertEqual(result.actionItems.first?.task, "draft RFC")
        XCTAssertEqual(result.actionItems.first?.owner, "Alex")
        XCTAssertEqual(result.entities.orgs, ["Acme"])
    }

    func testExtractWithCodeFences() async throws {
        let fenced = """
        ```json
        {
          "title": "T",
          "summary": "s",
          "key_ideas": [],
          "topics": [],
          "action_items": [],
          "entities": {"people": [], "places": [], "orgs": []},
          "cleaned_transcript": "t"
        }
        ```
        """
        let client = makeClient { request in
            return self.makeContentResponse(fenced)
        }
        let result = try await client.extract(transcript: "x", systemPrompt: "y")
        XCTAssertEqual(result.title, "T")
    }

    func testExtractRepairsMalformedFirstResponse() async throws {
        let attempts = ConcurrentCounter()
        let valid = """
        {"title":"R","summary":"s","key_ideas":[],"topics":[],"action_items":[],"entities":{"people":[],"places":[],"orgs":[]},"cleaned_transcript":"t"}
        """
        let client = makeClient { request in
            let n = attempts.increment()
            if n == 1 {
                return self.makeContentResponse("HERE'S THE OBJECT: {\"oops\"}")
            } else {
                return self.makeContentResponse(valid)
            }
        }
        let result = try await client.extract(transcript: "x", systemPrompt: "y")
        XCTAssertEqual(result.title, "R")
        XCTAssertEqual(attempts.current, 2)
    }

    func testExtractFailsAfterRepair() async {
        let client = makeClient { request in
            return self.makeContentResponse("not even close to json")
        }
        do {
            _ = try await client.extract(transcript: "x", systemPrompt: "y")
            XCTFail("expected throw")
        } catch ClaudeError.invalidJSON {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
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
                return self.makeContentResponse(valid)
            }
        }
        let result = try await client.extract(transcript: "x", systemPrompt: "y")
        XCTAssertEqual(result.title, "OK")
        XCTAssertEqual(attempts.current, 2)
    }

    func testSystemPromptResourceLoads() throws {
        let prompt = try ClaudeClient.loadSystemPrompt()
        XCTAssertFalse(prompt.isEmpty)
        XCTAssertTrue(prompt.contains("cleaned_transcript"), "prompt should mention cleaned_transcript field")
    }

    private func verifyExtractRequest(request: URLRequest, expectedSystemBlock: Bool) {
        guard let bodyData = request.httpBody ?? Self.bodyFromStream(request),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            XCTFail("could not decode request body")
            return
        }
        XCTAssertEqual(json["model"] as? String, "claude-haiku-4-5")
        if expectedSystemBlock {
            let system = json["system"] as? [[String: Any]]
            XCTAssertNotNil(system)
            XCTAssertEqual(system?.first?["type"] as? String, "text")
            let cache = system?.first?["cache_control"] as? [String: String]
            XCTAssertEqual(cache?["type"], "ephemeral")
        }
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

    private func makeContentResponse(_ text: String) -> (HTTPURLResponse, Data) {
        let envelope: [String: Any] = [
            "content": [["type": "text", "text": text]],
            "usage": [
                "input_tokens": 10,
                "output_tokens": 5,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: envelope)
        let resp = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/v1/messages")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (resp, data)
    }
}

final class ConcurrentCounter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ConcurrentCounter")
    private var value = 0
    func increment() -> Int { queue.sync { value += 1; return value } }
    var current: Int { queue.sync { value } }
}

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
