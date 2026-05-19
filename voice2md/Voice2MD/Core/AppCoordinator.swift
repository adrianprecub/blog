import Foundation
import Observation

@Observable
@MainActor
final class AppCoordinator {
    let config: AppConfig
    let store: ProcessedStore
    let watcher: Watcher
    let pipeline: Pipeline
    let status: StatusModel

    @ObservationIgnored
    private var watchTask: Task<Void, Never>?

    init(config: AppConfig, status: StatusModel) {
        self.config = config
        self.status = status
        self.store = ProcessedStore()
        self.watcher = Watcher(extensionAllowlist: config.extensionAllowlist)
        self.pipeline = Pipeline(store: store)
    }

    func start() {
        Task { await loadRecentFromStore() }
        startWatcher()
    }

    func restartWatcher() {
        startWatcher()
    }

    func processAllInInputFolder() async {
        guard let folder = config.resolveInputFolderURL() else {
            Notifier.notifyInfo("No input folder configured. Set one in Settings → General.")
            return
        }

        let allowed = Set(config.extensionAllowlist.map { $0.lowercased() })
        let didStart = folder.startAccessingSecurityScopedResource()
        defer { if didStart { folder.stopAccessingSecurityScopedResource() } }

        let urls: [URL]
        do {
            urls = try FileManager.default
                .contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                .filter { url in
                    let ext = url.pathExtension.lowercased()
                    guard allowed.contains(ext) else { return false }
                    let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey])
                        .isRegularFile) ?? false
                    return isRegular
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            AppLog.app.error("processAllInInputFolder: \(error.localizedDescription, privacy: .public)")
            Notifier.notifyError("Couldn't read input folder: \(error.localizedDescription)")
            return
        }

        if urls.isEmpty {
            Notifier.notifyInfo("No media files in the input folder.")
            return
        }

        AppLog.app.info("processAllInInputFolder: enumerating \(urls.count) files")

        var processed = 0
        var alreadyDone = 0
        var failed = 0

        for url in urls {
            status.startProcessing(url.lastPathComponent)
            let inputs = makeInputs(for: url)
            let outcome = await pipeline.process(inputs)

            if outcome.success {
                if outcome.skipped {
                    alreadyDone += 1
                    if case .processing = status.state { status.state = .idle }
                } else if let written = outcome.outputURL {
                    status.finishedProcessing(output: written)
                    processed += 1
                }
            } else {
                failed += 1
                status.recordError(outcome.error ?? "Pipeline failed")
            }
        }

        var parts: [String] = []
        if processed > 0 { parts.append("\(processed) processed") }
        if alreadyDone > 0 { parts.append("\(alreadyDone) already done") }
        if failed > 0 { parts.append("\(failed) failed") }
        let summary = parts.isEmpty ? "Nothing to do." : parts.joined(separator: ", ") + "."
        Notifier.notifyInfo(summary)
    }

    func reprocessMissing() async {
        let entries = await store.all()
        let toReprocess = entries.filter { entry in
            entry.status == .ok
                && entry.outputPath != nil
                && !FileManager.default.fileExists(atPath: entry.outputPath!)
                && FileManager.default.fileExists(atPath: entry.sourcePath)
        }
        let orphaned = entries.filter { entry in
            entry.status == .ok
                && entry.outputPath != nil
                && !FileManager.default.fileExists(atPath: entry.outputPath!)
                && !FileManager.default.fileExists(atPath: entry.sourcePath)
        }

        AppLog.app.info("reprocessMissing: \(toReprocess.count) to re-run, \(orphaned.count) orphaned")

        if toReprocess.isEmpty && orphaned.isEmpty {
            Notifier.notifyInfo("Nothing to re-process — all output files are present.")
            return
        }
        if toReprocess.isEmpty {
            Notifier.notifyInfo("Skipped \(orphaned.count) entr\(orphaned.count == 1 ? "y" : "ies") because the source file is gone.")
            return
        }

        var successCount = 0
        var errorCount = 0
        for entry in toReprocess {
            let url = URL(fileURLWithPath: entry.sourcePath)
            status.startProcessing(url.lastPathComponent)
            let inputs = makeInputs(for: url, forceReprocess: true)
            let outcome = await pipeline.process(inputs)

            if outcome.success {
                if let written = outcome.outputURL {
                    status.finishedProcessing(output: written)
                    successCount += 1
                } else if case .processing = status.state {
                    status.state = .idle
                }
            } else {
                status.recordError(outcome.error ?? "Pipeline failed")
                errorCount += 1
            }
        }

        var summary = "Re-processed \(successCount)."
        if errorCount > 0 {
            summary += " \(errorCount) failed."
        }
        if !orphaned.isEmpty {
            summary += " Skipped \(orphaned.count) (source missing)."
        }
        Notifier.notifyInfo(summary)
    }

    private func makeInputs(for url: URL, forceReprocess: Bool = false) -> Pipeline.Inputs {
        let extractor: (any AIExtractor)?
        let modelName: String?
        if config.useAIExtraction {
            switch config.aiProvider {
            case .anthropic:
                extractor = ClaudeClient(
                    apiKey: config.anthropicApiKey,
                    model: config.claudeModel
                )
                modelName = config.claudeModel
            case .azureOpenAI:
                extractor = AzureOpenAIClient(
                    apiKey: config.azureApiKey,
                    endpoint: config.azureEndpoint,
                    deployment: config.azureDeployment,
                    apiVersion: config.azureApiVersion
                )
                modelName = config.azureDeployment
            case .ollama:
                extractor = OllamaClient(
                    endpoint: config.ollamaEndpoint,
                    model: config.ollamaModel
                )
                modelName = config.ollamaModel
            }
        } else {
            extractor = nil
            modelName = nil
        }

        return Pipeline.Inputs(
            url: url,
            outputFolder: config.resolveOutputFolderURL(),
            whisperModelId: config.whisperModel,
            extractor: extractor,
            modelDisplayName: modelName,
            forceReprocess: forceReprocess
        )
    }

    private func loadRecentFromStore() async {
        let recent = await store.recent(limit: 10)
        let urls = recent.compactMap { entry -> URL? in
            entry.outputPath.map { URL(fileURLWithPath: $0) }
        }
        await MainActor.run { self.status.lastOutputs = urls }
    }

    private func startWatcher() {
        watchTask?.cancel()
        watcher.stop()
        watcher.updateAllowlist(config.extensionAllowlist)

        guard let folder = config.resolveInputFolderURL() else {
            AppLog.app.info("input folder not configured; watcher idle")
            return
        }

        let stream = watcher.start(watching: folder)
        let pipeline = self.pipeline
        let status = self.status
        let config = self.config
        let coordinator = self

        watchTask = Task { @MainActor in
            for await url in stream {
                if config.paused {
                    AppLog.pipeline.info("paused — skipping \(url.lastPathComponent, privacy: .public)")
                    continue
                }
                status.startProcessing(url.lastPathComponent)

                let inputs = coordinator.makeInputs(for: url)
                let outcome = await pipeline.process(inputs)

                if outcome.success {
                    if let written = outcome.outputURL {
                        status.finishedProcessing(output: written)
                    } else {
                        if case .processing = status.state { status.state = .idle }
                    }
                } else {
                    status.recordError(outcome.error ?? "Pipeline failed")
                    Notifier.notifyError(outcome.error ?? "Pipeline failed")
                }
            }
        }
    }
}
