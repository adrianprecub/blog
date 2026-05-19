import XCTest
@testable import Voice2MD

final class ProcessedStoreTests: XCTestCase {
    private var tmpURL: URL!

    override func setUpWithError() throws {
        tmpURL = FileManager.default.temporaryDirectory
            .appending(path: "processed-store-test-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpURL)
    }

    func testIdempotencyOnSameSha() async throws {
        let store = ProcessedStore(url: tmpURL)
        let entry = await store.seen(sha256: "abc123")
        XCTAssertNil(entry)

        try await store.markDone(
            sha256: "abc123",
            sourcePath: "/tmp/a.m4a",
            outputPath: "/tmp/a.md"
        )

        let again = await store.seen(sha256: "abc123")
        XCTAssertNotNil(again)
        XCTAssertEqual(again?.status, .ok)
        XCTAssertEqual(again?.outputPath, "/tmp/a.md")
    }

    func testPersistenceAcrossInstances() async throws {
        let first = ProcessedStore(url: tmpURL)
        try await first.markDone(
            sha256: "deadbeef",
            sourcePath: "/tmp/x.mp4",
            outputPath: "/tmp/x.md",
            model: "claude-haiku-4-5",
            whisperModel: "small.en"
        )

        let second = ProcessedStore(url: tmpURL)
        let entry = await second.seen(sha256: "deadbeef")
        XCTAssertEqual(entry?.outputPath, "/tmp/x.md")
        XCTAssertEqual(entry?.model, "claude-haiku-4-5")
        XCTAssertEqual(entry?.whisperModel, "small.en")
    }

    func testFailedAndOverwriteWithSuccess() async throws {
        let store = ProcessedStore(url: tmpURL)
        try await store.markFailed(
            sha256: "ff",
            sourcePath: "/tmp/a.m4a",
            error: "transcribe failed"
        )

        let failed = await store.seen(sha256: "ff")
        XCTAssertEqual(failed?.status, .failed)
        XCTAssertEqual(failed?.error, "transcribe failed")

        try await store.markDone(
            sha256: "ff",
            sourcePath: "/tmp/a.m4a",
            outputPath: "/tmp/a.md"
        )
        let done = await store.seen(sha256: "ff")
        XCTAssertEqual(done?.status, .ok)
        XCTAssertNil(done?.error)
    }

    func testAllReturnsAllEntriesIncludingFailed() async throws {
        let store = ProcessedStore(url: tmpURL)
        try await store.markDone(
            sha256: "older-ok",
            sourcePath: "/p1",
            outputPath: "/o1"
        )
        // Tiny sleep so processedAt timestamps differ.
        try await Task.sleep(for: .milliseconds(20))
        try await store.markFailed(
            sha256: "newer-failed",
            sourcePath: "/p2",
            error: "boom"
        )

        let all = await store.all()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].sha256, "newer-failed", "newest first")
        XCTAssertEqual(all[0].status, .failed)
        XCTAssertEqual(all[1].sha256, "older-ok")
        XCTAssertEqual(all[1].status, .ok)

        // recent() still filters to ok-only
        let recent = await store.recent(limit: 10)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].sha256, "older-ok")
    }

    func testJsonOnDiskIsValid() async throws {
        let store = ProcessedStore(url: tmpURL)
        try await store.markDone(
            sha256: "1",
            sourcePath: "/p1",
            outputPath: "/o1"
        )
        try await store.markDone(
            sha256: "2",
            sourcePath: "/p2",
            outputPath: "/o2"
        )

        let data = try Data(contentsOf: tmpURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = json?["entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.count, 2)
    }
}
