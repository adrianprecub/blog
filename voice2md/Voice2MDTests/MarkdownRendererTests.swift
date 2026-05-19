import XCTest
@testable import Voice2MD

final class MarkdownRendererTests: XCTestCase {
    func testGoldenRender() throws {
        let extraction = ExtractionResult(
            title: "Q3 Roadmap Review",
            summary: "Reviewed the Q3 roadmap with the engineering team and aligned on priorities.",
            keyIdeas: [
                "Ship feature X before mid-quarter",
                "Hire two senior engineers"
            ],
            topics: ["roadmap", "engineering"],
            actionItems: [
                ActionItem(task: "Draft RFC for feature X", owner: "Alex", due: "Friday"),
                ActionItem(task: "Schedule hiring sync", owner: nil, due: nil)
            ],
            entities: Entities(
                people: ["Alex", "Sam"],
                places: [],
                orgs: ["Acme Corp"]
            ),
            cleanedTranscript: "Today we reviewed the Q3 roadmap with the engineering team. Alex will draft the RFC for feature X by Friday."
        )
        let isoIn = ISO8601DateFormatter()
        let recordingDate = isoIn.date(from: "2025-11-07T14:30:00Z")!
        let processingDate = isoIn.date(from: "2025-11-07T14:40:00Z")!
        let media = MediaMetadata(
            recordingDate: recordingDate,
            durationSec: 92,
            sourceFormat: "m4a"
        )
        let source = PipelineSourceInfo(
            originalFilename: "memo-2025-11-07.m4a",
            sha256: "abc123def456",
            format: "m4a",
            transcribedWith: "small.en",
            aiModel: "claude-haiku-4-5"
        )
        let rendered = MarkdownRenderer.render(
            extraction: extraction,
            media: media,
            source: source,
            processingDate: processingDate,
            timeZone: TimeZone(identifier: "UTC")!
        )

        XCTAssertEqual(rendered.filename, "2025-11-07_1430_q3-roadmap-review.md")

        let expected = """
        ---
        title: 'Q3 Roadmap Review'
        recording_date: 2025-11-07T14:30:00Z
        processing_date: 2025-11-07T14:40:00Z
        source_media: 'memo-2025-11-07.m4a'
        source_format: m4a
        source_sha256: abc123def456
        duration_sec: 92
        transcribed_with: 'small.en'
        model: 'claude-haiku-4-5'
        tags:
          - 'roadmap'
          - 'engineering'
        ---

        ## Summary

        Reviewed the Q3 roadmap with the engineering team and aligned on priorities.

        ## Key Ideas

        - Ship feature X before mid-quarter
        - Hire two senior engineers

        ## Topics

        `roadmap`, `engineering`

        ## Action Items

        - [ ] Draft RFC for feature X — Alex (Friday)
        - [ ] Schedule hiring sync

        ## Entities

        - **People:** Alex, Sam
        - **Places:** _none_
        - **Organizations:** Acme Corp

        ## Cleaned Transcript

        Today we reviewed the Q3 roadmap with the engineering team. Alex will draft the RFC for feature X by Friday.

        """
        XCTAssertEqual(rendered.body, expected)
    }

    func testEmptyExtractionRendersGracefully() {
        let extraction = ExtractionResult(
            title: "Unintelligible memo",
            summary: "",
            keyIdeas: [],
            topics: [],
            actionItems: [],
            entities: Entities(people: [], places: [], orgs: []),
            cleanedTranscript: ""
        )
        let media = MediaMetadata(
            recordingDate: Date(timeIntervalSince1970: 1700000000),
            durationSec: 0,
            sourceFormat: "m4a"
        )
        let source = PipelineSourceInfo(
            originalFilename: "x.m4a",
            sha256: "0",
            format: "m4a",
            transcribedWith: "small.en",
            aiModel: "claude-haiku-4-5"
        )
        let rendered = MarkdownRenderer.render(
            extraction: extraction,
            media: media,
            source: source,
            processingDate: Date(timeIntervalSince1970: 1700000000),
            timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertTrue(rendered.body.contains("tags: []"))
        XCTAssertTrue(rendered.body.contains("_None._"))
        XCTAssertTrue(rendered.body.hasSuffix("## Cleaned Transcript\n\n\n"))
    }

    func testRenderPlainGolden() throws {
        let isoIn = ISO8601DateFormatter()
        let recordingDate = isoIn.date(from: "2026-05-07T19:39:00Z")!
        let processingDate = isoIn.date(from: "2026-05-08T11:00:00Z")!
        let media = MediaMetadata(
            recordingDate: recordingDate,
            durationSec: 6986,
            sourceFormat: "m4a"
        )
        let source = PipelineSourceInfo(
            originalFilename: "Piotr 1:1 .m4a",
            sha256: "deadbeef",
            format: "m4a",
            transcribedWith: "small.en",
            aiModel: nil
        )
        let rendered = MarkdownRenderer.renderPlain(
            transcript: "Hello, this is the recording.\nSecond paragraph here.",
            media: media,
            source: source,
            processingDate: processingDate,
            timeZone: TimeZone(identifier: "UTC")!
        )

        XCTAssertEqual(rendered.filename, "2026-05-07_1939_piotr-1-1.md")

        let expected = """
        ---
        title: 'Piotr 1:1'
        recording_date: 2026-05-07T19:39:00Z
        processing_date: 2026-05-08T11:00:00Z
        source_media: 'Piotr 1:1 .m4a'
        source_format: m4a
        source_sha256: deadbeef
        duration_sec: 6986
        transcribed_with: 'small.en'
        ---

        # Piotr 1:1

        Hello, this is the recording.
        Second paragraph here.

        """
        XCTAssertEqual(rendered.body, expected)
    }

    func testRenderPlainWithAppleEmbeddedSource() {
        let media = MediaMetadata(
            recordingDate: Date(timeIntervalSince1970: 1700000000),
            durationSec: 60,
            sourceFormat: "m4a"
        )
        let source = PipelineSourceInfo(
            originalFilename: "memo.m4a",
            sha256: "0",
            format: "m4a",
            transcribedWith: "apple-embedded",
            aiModel: nil
        )
        let rendered = MarkdownRenderer.renderPlain(
            transcript: "Body text.",
            media: media,
            source: source,
            processingDate: Date(timeIntervalSince1970: 1700000000),
            timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertTrue(rendered.body.contains("transcribed_with: 'apple-embedded'"))
        XCTAssertFalse(rendered.body.contains("model:"), "plain mode should not emit model field")
        XCTAssertFalse(rendered.body.contains("tags:"), "plain mode should not emit tags field")
        XCTAssertTrue(rendered.body.contains("# memo\n\nBody text."))
    }

    func testSlugifyTitle() {
        XCTAssertEqual(Slug.make("Q3 Roadmap Review"), "q3-roadmap-review")
        XCTAssertEqual(Slug.make("Schöne Idee — let's go!"), "schone-idee-let-s-go")
        XCTAssertEqual(Slug.make(""), "untitled")
        XCTAssertEqual(Slug.make("---"), "untitled")
        XCTAssertEqual(Slug.make("a"), "a")
    }

    func testUniqueURLAppendsCounterOnCollision() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "vm2md-collision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let base = dir.appending(path: "2025-11-07_1430_meeting.md")
        try "first".write(to: base, atomically: true, encoding: .utf8)

        let unique1 = Pipeline.uniqueURL(base: base)
        XCTAssertEqual(unique1.lastPathComponent, "2025-11-07_1430_meeting-1.md")

        try "second".write(to: unique1, atomically: true, encoding: .utf8)
        let unique2 = Pipeline.uniqueURL(base: base)
        XCTAssertEqual(unique2.lastPathComponent, "2025-11-07_1430_meeting-2.md")
    }
}
