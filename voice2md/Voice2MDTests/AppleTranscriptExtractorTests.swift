import XCTest
@testable import Voice2MD

final class AppleTranscriptExtractorTests: XCTestCase {

    // MARK: - JSON parsing

    func testParseTsrpPayloadHappyPath() {
        let json = #"""
        {"attributedString":{"runs":["Hello world",{"attributes":{}},". This is a test."]}}
        """#
        let result = AppleTranscriptExtractor.parseTsrpPayload(Data(json.utf8))
        XCTAssertEqual(result, "Hello world. This is a test.")
    }

    func testParseTsrpPayloadAllStringRuns() {
        let json = #"""
        {"attributedString":{"runs":["one ","two ","three"]}}
        """#
        let result = AppleTranscriptExtractor.parseTsrpPayload(Data(json.utf8))
        XCTAssertEqual(result, "one two three")
    }

    func testParseTsrpPayloadNoRuns() {
        let json = #"""
        {"attributedString":{"runs":[]}}
        """#
        XCTAssertNil(AppleTranscriptExtractor.parseTsrpPayload(Data(json.utf8)))
    }

    func testParseTsrpPayloadOnlyAttributeRuns() {
        let json = #"""
        {"attributedString":{"runs":[{"attributes":{}},{"attributes":{}}]}}
        """#
        XCTAssertNil(AppleTranscriptExtractor.parseTsrpPayload(Data(json.utf8)))
    }

    func testParseTsrpPayloadPlainStringForm() {
        let json = #"""
        {"locale":{"identifier":"en_US"},"attributedString":"Hello, this is a recorded memo."}
        """#
        XCTAssertEqual(
            AppleTranscriptExtractor.parseTsrpPayload(Data(json.utf8)),
            "Hello, this is a recorded memo."
        )
    }

    func testParseTsrpPayloadEmptyAttributedStringReturnsNil() {
        // Real iPad Voice Memos sometimes write tsrp with locale info but
        // an empty attributedString — transcript not yet generated/embedded.
        let json = #"""
        {"locale":{"identifier":"en_US"},"attributedString":""}
        """#
        XCTAssertNil(AppleTranscriptExtractor.parseTsrpPayload(Data(json.utf8)))
    }

    func testParseTsrpPayloadMalformedReturnsNil() {
        XCTAssertNil(AppleTranscriptExtractor.parseTsrpPayload(Data("not json".utf8)))
        XCTAssertNil(AppleTranscriptExtractor.parseTsrpPayload(Data("{}".utf8)))
        XCTAssertNil(AppleTranscriptExtractor.parseTsrpPayload(Data(#"{"attributedString":{}}"#.utf8)))
    }

    // MARK: - Atom walker (synthesized MP4 blob)

    func testFindAtomDeepPath() throws {
        let payload = Data(#"{"attributedString":{"runs":["meeting on Tuesday"]}}"#.utf8)
        let blob = makeAtom("moov", payload:
            makeAtom("trak", payload:
                makeAtom("udta", payload:
                    makeAtom("tsrp", payload: payload)
                )
            )
        )
        let url = try writeTempFile(data: blob)
        defer { try? FileManager.default.removeItem(at: url) }

        let extracted = AppleTranscriptExtractor.extract(from: url)
        XCTAssertEqual(extracted, "meeting on Tuesday")
    }

    func testFindAtomMultipleTraksPicksRightOne() throws {
        let payload = Data(#"{"attributedString":{"runs":["second trak hit"]}}"#.utf8)
        // First trak has no udta. Second trak has udta/tsrp.
        let firstTrak = makeAtom("trak", payload: makeAtom("mdia", payload: Data(repeating: 0, count: 16)))
        let secondTrak = makeAtom("trak", payload:
            makeAtom("udta", payload: makeAtom("tsrp", payload: payload))
        )
        let blob = makeAtom("moov", payload: firstTrak + secondTrak)
        let url = try writeTempFile(data: blob)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(AppleTranscriptExtractor.extract(from: url), "second trak hit")
    }

    func testNoTsrpReturnsNil() throws {
        let blob = makeAtom("moov", payload:
            makeAtom("trak", payload:
                makeAtom("udta", payload: Data(repeating: 0, count: 32))
            )
        )
        let url = try writeTempFile(data: blob)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(AppleTranscriptExtractor.extract(from: url))
    }

    func testNonExistentFileReturnsNil() {
        let url = URL(fileURLWithPath: "/no/such/file/\(UUID().uuidString).m4a")
        XCTAssertNil(AppleTranscriptExtractor.extract(from: url))
    }

    func testRandomBlobReturnsNil() throws {
        let url = try writeTempFile(data: Data((0..<128).map { _ in UInt8.random(in: 0...255) }))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(AppleTranscriptExtractor.extract(from: url))
    }

    // MARK: - Helpers

    private func makeAtom(_ type: String, payload: Data) -> Data {
        precondition(type.count == 4, "atom type must be 4 ASCII chars")
        var data = Data()
        var size = UInt32(8 + payload.count).bigEndian
        data.append(Data(bytes: &size, count: 4))
        data.append(type.data(using: .ascii)!)
        data.append(payload)
        return data
    }

    private func writeTempFile(data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "atom-test-\(UUID().uuidString).m4a")
        try data.write(to: url)
        return url
    }
}
