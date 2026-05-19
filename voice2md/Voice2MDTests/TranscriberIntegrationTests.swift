import XCTest
@testable import Voice2MD

final class TranscriberIntegrationTests: XCTestCase {
    func testTranscribeSynthesizedM4A() async throws {
        let modelURL = URL(fileURLWithPath: NSString(string: "~/Library/Application Support/Voice2MD/models/ggml-small.en.bin").expandingTildeInPath)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: modelURL.path),
            "small.en model not present at \(modelURL.path); skip integration test"
        )

        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "vm2md-itest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let aiff = tmp.appending(path: "speech.aiff")
        let m4a = tmp.appending(path: "speech.m4a")

        let phrase = "Hello, this is a quick test memo about the project plan."
        try synthesizeSpeech(text: phrase, to: aiff)
        try convert(input: aiff, output: m4a, codec: "aac")

        let transcriber = Transcriber(modelURL: modelURL)
        let result = try await transcriber.transcribe(url: m4a)

        let cleaned = result.text.lowercased()
        XCTAssertTrue(cleaned.contains("test memo"), "expected 'test memo' in transcript, got: \(result.text)")
        XCTAssertTrue(cleaned.contains("project plan"), "expected 'project plan' in transcript, got: \(result.text)")
        XCTAssertGreaterThan(result.durationSec, 0.5)
        XCTAssertLessThan(result.durationSec, 30)
    }

    private func synthesizeSpeech(text: String, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, text]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func convert(input: URL, output: URL, codec: String) throws {
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let path = ffmpeg else {
            throw XCTSkip("ffmpeg not available")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-y", "-i", input.path, "-c:a", codec, "-b:a", "64k", output.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
