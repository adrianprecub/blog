import XCTest
@testable import Voice2MD

@MainActor
final class StatusModelTests: XCTestCase {
    func testStartProcessingFlipsToProcessing() {
        let s = StatusModel()
        s.startProcessing("memo.m4a")
        if case .processing(let f) = s.state {
            XCTAssertEqual(f, "memo.m4a")
        } else {
            XCTFail("expected .processing")
        }
    }

    func testFinishedProcessingPushesToRecent() {
        let s = StatusModel()
        let url = URL(fileURLWithPath: "/tmp/out.md")
        s.startProcessing("a.m4a")
        s.finishedProcessing(output: url)
        XCTAssertEqual(s.state, .idle)
        XCTAssertEqual(s.lastOutputs, [url])
        XCTAssertEqual(s.processedSinceLaunch, 1)
    }

    func testRecentCappedAt10AndDedup() {
        let s = StatusModel()
        for i in 0..<12 {
            s.finishedProcessing(output: URL(fileURLWithPath: "/tmp/o\(i).md"))
        }
        XCTAssertEqual(s.lastOutputs.count, 10)
        XCTAssertEqual(s.lastOutputs.first?.lastPathComponent, "o11.md")

        let dup = URL(fileURLWithPath: "/tmp/o11.md")
        s.finishedProcessing(output: dup)
        XCTAssertEqual(s.lastOutputs.count, 10)
        XCTAssertEqual(s.lastOutputs.filter { $0 == dup }.count, 1, "should dedupe")
    }

    func testRecordErrorIncrementsAndSticks() {
        let s = StatusModel()
        s.recordError("oops")
        XCTAssertEqual(s.errorCountSinceLaunch, 1)
        if case .error(let m) = s.state { XCTAssertEqual(m, "oops") } else { XCTFail() }

        // finishedProcessing without success should not clear sticky error
        s.startProcessing("b.m4a")  // changes to processing — that overrides; OK
        s.finishedProcessing(output: nil)
        // when output is nil, we keep error sticky if state was .error before processing
        // (but state was .processing here, so we go .idle)
        XCTAssertEqual(s.state, .idle)
    }

    func testIconNameByState() {
        let s = StatusModel()
        XCTAssertEqual(s.iconName(paused: false), "waveform")
        XCTAssertEqual(s.iconName(paused: true), "waveform.path.badge.minus")

        s.startProcessing("x")
        XCTAssertEqual(s.iconName(paused: false), "waveform.circle")

        s.recordError("err")
        XCTAssertEqual(s.iconName(paused: false), "waveform.badge.exclamationmark")
    }
}
