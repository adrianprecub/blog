import Foundation

actor Pipeline {
    private let store: ProcessedStore
    private let systemPrompt: String

    init(store: ProcessedStore) {
        self.store = store
        self.systemPrompt = (try? ClaudeClient.loadSystemPrompt()) ?? ""
        if systemPrompt.isEmpty {
            AppLog.claude.error("extraction system prompt missing from bundle")
        }
    }

    struct Inputs: Sendable {
        let url: URL
        let outputFolder: URL?
        let whisperModelId: String
        let extractor: (any AIExtractor)?
        let modelDisplayName: String?
        let forceReprocess: Bool

        init(
            url: URL,
            outputFolder: URL?,
            whisperModelId: String,
            extractor: (any AIExtractor)?,
            modelDisplayName: String?,
            forceReprocess: Bool = false
        ) {
            self.url = url
            self.outputFolder = outputFolder
            self.whisperModelId = whisperModelId
            self.extractor = extractor
            self.modelDisplayName = modelDisplayName
            self.forceReprocess = forceReprocess
        }
    }

    struct Outcome: Sendable {
        let success: Bool
        let outputURL: URL?
        let error: String?
        let skipped: Bool
    }

    func process(_ inputs: Inputs) async -> Outcome {
        let url = inputs.url
        let log = AppLog.pipeline
        let sha: String
        do {
            sha = try Sha256.hash(fileAt: url)
        } catch {
            let msg = "sha256 failed for \(url.lastPathComponent): \(error.localizedDescription)"
            log.error("\(msg, privacy: .public)")
            return Outcome(success: false, outputURL: nil, error: msg, skipped: false)
        }

        if !inputs.forceReprocess, let entry = await store.seen(sha256: sha) {
            log.info("[seen] \(sha, privacy: .public) → skipping (\(entry.status.rawValue, privacy: .public))")
            return Outcome(success: true, outputURL: nil, error: nil, skipped: true)
        }

        guard let outputFolder = inputs.outputFolder else {
            let msg = "output folder not configured"
            log.error("\(msg, privacy: .public)")
            try? await store.markFailed(sha256: sha, sourcePath: url.path, error: msg)
            return Outcome(success: false, outputURL: nil, error: msg, skipped: false)
        }

        log.info("[new] \(sha, privacy: .public) — \(url.lastPathComponent, privacy: .public)")

        let modelURL = await MainActor.run {
            WhisperModelManager.modelURL(forId: inputs.whisperModelId)
        }
        let transcriber = Transcriber(modelURL: modelURL)

        do {
            let transcription = try await transcriber.transcribe(url: url)
            log.info("transcript (\(Int(transcription.durationSec)) s, source=\(transcription.source.label, privacy: .public)): \(String(transcription.text.prefix(160)), privacy: .public)")

            var media = await MediaMetadataReader.read(url)
            if media.durationSec == 0, transcription.durationSec > 0 {
                media = MediaMetadata(
                    recordingDate: media.recordingDate,
                    durationSec: transcription.durationSec,
                    sourceFormat: media.sourceFormat
                )
            }

            let source = PipelineSourceInfo(
                originalFilename: url.lastPathComponent,
                sha256: sha,
                format: url.pathExtension.lowercased(),
                transcribedWith: transcription.source.label,
                aiModel: inputs.modelDisplayName
            )

            let rendered: RenderedMarkdown
            if let extractor = inputs.extractor {
                let extraction = try await extractor.extract(
                    transcript: transcription.text,
                    systemPrompt: systemPrompt
                )
                log.info("extracted '\(extraction.title, privacy: .public)' — ideas:\(extraction.keyIdeas.count) topics:\(extraction.topics.count) actions:\(extraction.actionItems.count)")
                rendered = MarkdownRenderer.render(
                    extraction: extraction,
                    media: media,
                    source: source
                )
            } else {
                log.info("AI extraction disabled — writing plain transcript")
                rendered = MarkdownRenderer.renderPlain(
                    transcript: transcription.text,
                    media: media,
                    source: source
                )
            }

            let didStart = outputFolder.startAccessingSecurityScopedResource()
            defer { if didStart { outputFolder.stopAccessingSecurityScopedResource() } }

            try FileManager.default.createDirectory(
                at: outputFolder,
                withIntermediateDirectories: true
            )
            let writtenURL = try Self.writeRendered(rendered, into: outputFolder)
            log.info("wrote \(writtenURL.lastPathComponent, privacy: .public)")

            try await store.markDone(
                sha256: sha,
                sourcePath: url.path,
                outputPath: writtenURL.path,
                model: inputs.modelDisplayName,
                whisperModel: transcription.source.label
            )
            return Outcome(success: true, outputURL: writtenURL, error: nil, skipped: false)
        } catch {
            let msg = error.localizedDescription
            log.error("pipeline failed: \(msg, privacy: .public)")
            try? await store.markFailed(
                sha256: sha,
                sourcePath: url.path,
                error: msg
            )
            return Outcome(success: false, outputURL: nil, error: msg, skipped: false)
        }
    }

    static func writeRendered(_ rendered: RenderedMarkdown, into folder: URL) throws -> URL {
        let base = folder.appending(path: rendered.filename)
        let target = uniqueURL(base: base)
        try rendered.body.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    static func uniqueURL(base: URL) -> URL {
        if !FileManager.default.fileExists(atPath: base.path) {
            return base
        }
        let parent = base.deletingLastPathComponent()
        let stem = base.deletingPathExtension().lastPathComponent
        let ext = base.pathExtension
        for i in 1..<1000 {
            let candidate = parent.appending(path: "\(stem)-\(i).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return parent.appending(path: "\(stem)-\(UUID().uuidString).\(ext)")
    }
}
