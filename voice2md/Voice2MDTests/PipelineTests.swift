import XCTest
@testable import Voice2MD

final class PipelineTests: XCTestCase {
    private var storeURL: URL!
    private var fixturesDir: URL!

    override func setUpWithError() throws {
        storeURL = FileManager.default.temporaryDirectory
            .appending(path: "pipeline-store-\(UUID().uuidString).json")
        fixturesDir = FileManager.default.temporaryDirectory
            .appending(path: "pipeline-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixturesDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeURL)
        try? FileManager.default.removeItem(at: fixturesDir)
    }

    func testSkippedWhenAlreadySeen() async throws {
        let store = ProcessedStore(url: storeURL)
        let pipeline = Pipeline(store: store)

        let dummy = fixturesDir.appending(path: "memo.m4a")
        try Data("hello world".utf8).write(to: dummy)

        let sha = try Sha256.hash(fileAt: dummy)
        try await store.markDone(
            sha256: sha,
            sourcePath: dummy.path,
            outputPath: "/tmp/old.md"
        )

        let outcome = await pipeline.process(.init(
            url: dummy,
            outputFolder: fixturesDir,
            whisperModelId: "small.en",
            extractor: ClaudeClient(apiKey: "", model: "claude-haiku-4-5"),
            modelDisplayName: "claude-haiku-4-5"
        ))

        XCTAssertTrue(outcome.skipped)
        XCTAssertTrue(outcome.success)
        XCTAssertNil(outcome.outputURL)
    }

    func testFailsWhenOutputFolderMissing() async throws {
        let store = ProcessedStore(url: storeURL)
        let pipeline = Pipeline(store: store)

        let dummy = fixturesDir.appending(path: "memo.m4a")
        try Data("a b c".utf8).write(to: dummy)

        let outcome = await pipeline.process(.init(
            url: dummy,
            outputFolder: nil,
            whisperModelId: "small.en",
            extractor: ClaudeClient(apiKey: "sk-ant-test", model: "claude-haiku-4-5"),
            modelDisplayName: "claude-haiku-4-5"
        ))

        XCTAssertFalse(outcome.success)
        XCTAssertEqual(outcome.error, "output folder not configured")

        let sha = try Sha256.hash(fileAt: dummy)
        let entry = await store.seen(sha256: sha)
        XCTAssertEqual(entry?.status, .failed)
    }

    func testWritesPlainMarkdownWhenExtractorIsNil() async throws {
        let store = ProcessedStore(url: storeURL)
        let pipeline = Pipeline(store: store)

        // Synthesize a minimal .m4a with the embedded Apple transcript atom.
        let payload = Data(#"{"attributedString":{"runs":["Hello from the embedded transcript."]}}"#.utf8)
        let blob = atom("moov", payload:
            atom("trak", payload:
                atom("udta", payload: atom("tsrp", payload: payload))
            )
        )
        let media = fixturesDir.appending(path: "memo.m4a")
        try blob.write(to: media)

        let outcome = await pipeline.process(.init(
            url: media,
            outputFolder: fixturesDir,
            whisperModelId: "small.en",
            extractor: nil,
            modelDisplayName: nil
        ))

        XCTAssertTrue(outcome.success, "expected success, error=\(outcome.error ?? "nil")")
        XCTAssertNotNil(outcome.outputURL)
        let mdContents = try String(contentsOf: outcome.outputURL!)
        XCTAssertTrue(mdContents.contains("# memo"), "expected H1 from filename — got \(mdContents)")
        XCTAssertTrue(mdContents.contains("Hello from the embedded transcript."))
        XCTAssertTrue(mdContents.contains("transcribed_with: 'apple-embedded'"))
        XCTAssertFalse(mdContents.contains("model:"), "plain mode should not emit model")
        XCTAssertFalse(mdContents.contains("tags:"), "plain mode should not emit tags")
        XCTAssertFalse(mdContents.contains("## Summary"))
    }

    private func atom(_ type: String, payload: Data) -> Data {
        var data = Data()
        var size = UInt32(8 + payload.count).bigEndian
        data.append(Data(bytes: &size, count: 4))
        data.append(type.data(using: .ascii)!)
        data.append(payload)
        return data
    }

    func testForceReprocessBypassesSeenCheck() async throws {
        let store = ProcessedStore(url: storeURL)
        let pipeline = Pipeline(store: store)

        let payload = Data(#"{"attributedString":{"runs":["Re-processed transcript content."]}}"#.utf8)
        let blob = atom("moov", payload:
            atom("trak", payload:
                atom("udta", payload: atom("tsrp", payload: payload))
            )
        )
        let media = fixturesDir.appending(path: "memo.m4a")
        try blob.write(to: media)

        let sha = try Sha256.hash(fileAt: media)
        try await store.markDone(
            sha256: sha,
            sourcePath: media.path,
            outputPath: "/tmp/old-stale-path.md"
        )

        // Without forceReprocess: would skip
        let skipOutcome = await pipeline.process(.init(
            url: media,
            outputFolder: fixturesDir,
            whisperModelId: "small.en",
            extractor: nil,
            modelDisplayName: nil
        ))
        XCTAssertTrue(skipOutcome.skipped, "default path should still skip when seen")
        XCTAssertNil(skipOutcome.outputURL)

        // With forceReprocess: should run
        let outcome = await pipeline.process(.init(
            url: media,
            outputFolder: fixturesDir,
            whisperModelId: "small.en",
            extractor: nil,
            modelDisplayName: nil,
            forceReprocess: true
        ))
        XCTAssertFalse(outcome.skipped, "force should not skip")
        XCTAssertTrue(outcome.success)
        XCTAssertNotNil(outcome.outputURL)
        let written = try String(contentsOf: outcome.outputURL!)
        XCTAssertTrue(written.contains("Re-processed transcript content."))

        let entry = await store.seen(sha256: sha)
        XCTAssertEqual(entry?.outputPath, outcome.outputURL?.path, "entry must be updated to the fresh output path")
        XCTAssertNotEqual(entry?.outputPath, "/tmp/old-stale-path.md")
    }

    func testWriteRenderedHandlesCollision() throws {
        let folder = fixturesDir!
        let rendered = RenderedMarkdown(
            filename: "2025-11-07_1430_test.md",
            body: "first body"
        )

        let first = try Pipeline.writeRendered(rendered, into: folder)
        XCTAssertEqual(first.lastPathComponent, "2025-11-07_1430_test.md")
        XCTAssertEqual(try String(contentsOf: first), "first body")

        let collide = RenderedMarkdown(
            filename: "2025-11-07_1430_test.md",
            body: "second body"
        )
        let second = try Pipeline.writeRendered(collide, into: folder)
        XCTAssertEqual(second.lastPathComponent, "2025-11-07_1430_test.md-1.md".replacingOccurrences(of: ".md-1.md", with: "-1.md"))
        XCTAssertEqual(try String(contentsOf: second), "second body")
        XCTAssertEqual(try String(contentsOf: first), "first body", "first file untouched")
    }
}
