import XCTest
@testable import Voice2MD

final class Sha256Tests: XCTestCase {
    func testKnownVector() throws {
        let url = try writeTempFile(contents: Data("hello".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let hash = try Sha256.hash(fileAt: url)
        XCTAssertEqual(
            hash,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
            "sha256 of 'hello' should match the well-known vector"
        )
    }

    func testEmptyFile() throws {
        let url = try writeTempFile(contents: Data())
        defer { try? FileManager.default.removeItem(at: url) }
        let hash = try Sha256.hash(fileAt: url)
        XCTAssertEqual(
            hash,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func testStreamingLargeFile() throws {
        // 5 MB of zero bytes — exercises the chunked read loop.
        let bytes = Data(count: 5 * 1024 * 1024)
        let url = try writeTempFile(contents: bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let hash = try Sha256.hash(fileAt: url)
        XCTAssertEqual(hash.count, 64)
        XCTAssertTrue(hash.allSatisfy { "0123456789abcdef".contains($0) })
    }

    private func writeTempFile(contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "sha256-test-\(UUID().uuidString)")
        try contents.write(to: url)
        return url
    }
}
