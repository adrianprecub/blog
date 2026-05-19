import Foundation

struct TranscriptionResult: Sendable {
    let text: String
    let durationSec: Double
    let source: TranscriptionSource
}

enum TranscriptionSource: Sendable, Equatable {
    case appleEmbedded
    case whisper(model: String)

    var label: String {
        switch self {
        case .appleEmbedded: return "apple-embedded"
        case .whisper(let model): return model
        }
    }
}

enum TranscriberError: Error, LocalizedError {
    case toolMissing(String, brewCommand: String)
    case modelMissing(URL)
    case ffmpegFailed(String)
    case whisperFailed(String)
    case ioError(String)

    var errorDescription: String? {
        switch self {
        case .toolMissing(let name, let cmd):
            return "Missing CLI tool: \(name). Install with: \(cmd)"
        case .modelMissing(let url):
            return "Whisper model not found at \(url.lastPathComponent). Open Settings → Transcription → Download."
        case .ffmpegFailed(let msg):
            return "ffmpeg failed: \(msg)"
        case .whisperFailed(let msg):
            return "whisper-cli failed: \(msg)"
        case .ioError(let msg):
            return "I/O error: \(msg)"
        }
    }
}

final class Transcriber: Sendable {
    private let modelURL: URL

    init(modelURL: URL) {
        self.modelURL = modelURL
    }

    func transcribe(url: URL) async throws -> TranscriptionResult {
        if let embedded = AppleTranscriptExtractor.extract(from: url) {
            AppLog.whisper.info("using embedded Apple transcript for \(url.lastPathComponent, privacy: .public) (\(embedded.count) chars)")
            return TranscriptionResult(text: embedded, durationSec: 0, source: .appleEmbedded)
        }
        AppLog.whisper.info("no embedded transcript; running whisper for \(url.lastPathComponent, privacy: .public)")

        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw TranscriberError.modelMissing(modelURL)
        }
        let ffmpeg = try Self.locate("ffmpeg")
        let whisper = try Self.locate("whisper-cli")

        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "vm2md-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let wavURL = tmpDir.appending(path: "input.wav")
        let txtPrefix = tmpDir.appending(path: "transcript")

        AppLog.whisper.info("ffmpeg → wav for \(url.lastPathComponent, privacy: .public)")
        let ffmpegResult = try await runProcess(
            executable: ffmpeg,
            args: ["-y", "-i", url.path, "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wavURL.path]
        )
        guard ffmpegResult.exitCode == 0 else {
            throw TranscriberError.ffmpegFailed(String(ffmpegResult.stderr.suffix(500)))
        }
        let durationSec = Self.parseDuration(from: ffmpegResult.stderr) ?? 0

        AppLog.whisper.info("whisper-cli on \(wavURL.lastPathComponent, privacy: .public) (model=\(self.modelURL.lastPathComponent, privacy: .public))")
        let whisperResult = try await runProcess(
            executable: whisper,
            args: [
                "-m", modelURL.path,
                "-f", wavURL.path,
                "-l", "en",
                "-otxt",
                "-of", txtPrefix.path,
                "-np",
                "-nt"
            ]
        )
        guard whisperResult.exitCode == 0 else {
            throw TranscriberError.whisperFailed(String(whisperResult.stderr.suffix(500)))
        }

        let txtURL = URL(fileURLWithPath: txtPrefix.path + ".txt")
        guard let data = try? Data(contentsOf: txtURL),
              let text = String(data: data, encoding: .utf8) else {
            throw TranscriberError.ioError("could not read whisper output at \(txtURL.path)")
        }

        let modelId = modelURL
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "ggml-", with: "")
        return TranscriptionResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            durationSec: durationSec,
            source: .whisper(model: modelId)
        )
    }

    static let toolSearchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin"
    ]

    static func isToolPresent(_ name: String) -> Bool {
        for dir in toolSearchPaths where FileManager.default.isExecutableFile(atPath: "\(dir)/\(name)") {
            return true
        }
        return false
    }

    private static func locate(_ name: String) throws -> URL {
        for dir in toolSearchPaths {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        throw TranscriberError.toolMissing(name, brewCommand: "brew install whisper-cpp ffmpeg")
    }

    private struct ProcessResult: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private func runProcess(executable: URL, args: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            process.terminationHandler = { p in
                let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                cont.resume(returning: ProcessResult(
                    exitCode: p.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                ))
            }

            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    private static func parseDuration(from ffmpegStderr: String) -> Double? {
        guard let match = ffmpegStderr.range(
            of: #"Duration: (\d+):(\d+):(\d+)\.(\d+)"#,
            options: .regularExpression
        ) else { return nil }
        let portion = String(ffmpegStderr[match])
        let nums = portion
            .replacingOccurrences(of: "Duration: ", with: "")
            .split(whereSeparator: { ":.".contains($0) })
            .compactMap { Double($0) }
        guard nums.count == 4 else { return nil }
        return nums[0] * 3600 + nums[1] * 60 + nums[2] + nums[3] / 100
    }
}
