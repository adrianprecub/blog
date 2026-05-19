import Foundation
import Observation

@Observable
@MainActor
final class WhisperModelManager {
    struct ModelOption: Identifiable, Sendable, Hashable {
        let id: String
        let displayName: String
        let sizeMB: Int
        let useCase: String
        let downloadURL: URL
    }

    static let allModels: [ModelOption] = [
        .init(
            id: "small.en",
            displayName: "small.en",
            sizeMB: 466,
            useCase: "Default — clean speech, single speaker",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin")!
        ),
        .init(
            id: "medium.en",
            displayName: "medium.en",
            sizeMB: 1500,
            useCase: "Mumbled speech, mild background noise",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en.bin")!
        ),
        .init(
            id: "large-v3-turbo",
            displayName: "large-v3-turbo",
            sizeMB: 1620,
            useCase: "Best for multi-speaker / noisy memos",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!
        ),
        .init(
            id: "large-v3",
            displayName: "large-v3",
            sizeMB: 2950,
            useCase: "Highest accuracy, slowest",
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin")!
        )
    ]

    enum DownloadState: Sendable, Equatable {
        case notStarted
        case downloading(progress: Double)
        case finished
        case failed(String)
    }

    private(set) var states: [String: DownloadState] = [:]

    static func modelsDirectory() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let dir = appSupport
            .appending(path: "Voice2MD")
            .appending(path: "models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func modelURL(forId id: String) -> URL {
        modelsDirectory().appending(path: "ggml-\(id).bin")
    }

    static func option(forId id: String) -> ModelOption? {
        allModels.first { $0.id == id }
    }

    func isPresent(id: String) -> Bool {
        FileManager.default.fileExists(atPath: Self.modelURL(forId: id).path)
    }

    func download(_ option: ModelOption) async {
        states[option.id] = .downloading(progress: 0)
        let dest = Self.modelURL(forId: option.id)
        let onProgress: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in
                self?.states[option.id] = .downloading(progress: p)
            }
        }

        do {
            let downloaded = try await ModelDownloader.download(
                from: option.downloadURL,
                onProgress: onProgress
            )
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: downloaded, to: dest)
            let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
            let bytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
            guard bytes > 10 * 1024 * 1024 else {
                try? FileManager.default.removeItem(at: dest)
                throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: "downloaded file too small (\(bytes) bytes)"])
            }
            states[option.id] = .finished
            AppLog.whisper.info("downloaded \(option.id, privacy: .public) (\(bytes) bytes)")
        } catch {
            states[option.id] = .failed(error.localizedDescription)
            AppLog.whisper.error("download failed for \(option.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

private enum ModelDownloader {
    static func download(
        from url: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let delegate = ProgressDelegate(onProgress: onProgress) { result in
                switch result {
                case .success(let u): cont.resume(returning: u)
                case .failure(let e): cont.resume(throwing: e)
                }
            }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let onProgress: @Sendable (Double) -> Void
        let onComplete: @Sendable (Result<URL, Error>) -> Void
        private var didFinish = false

        init(
            onProgress: @escaping @Sendable (Double) -> Void,
            onComplete: @escaping @Sendable (Result<URL, Error>) -> Void
        ) {
            self.onProgress = onProgress
            self.onComplete = onComplete
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            let dest = FileManager.default.temporaryDirectory
                .appending(path: "vm2md-dl-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: location, to: dest)
                didFinish = true
                onComplete(.success(dest))
            } catch {
                didFinish = true
                onComplete(.failure(error))
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            if didFinish { return }
            if let error {
                didFinish = true
                onComplete(.failure(error))
            }
        }
    }
}
