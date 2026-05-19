import Foundation

actor ProcessedStore {
    struct Entry: Codable, Sendable {
        let sha256: String
        let sourcePath: String
        let outputPath: String?
        let processedAt: Date
        let status: Status
        let error: String?
        let model: String?
        let whisperModel: String?
    }

    enum Status: String, Codable, Sendable {
        case ok
        case failed
    }

    private struct FileFormat: Codable {
        var entries: [Entry]
    }

    private let url: URL
    private var cache: [String: Entry] = [:]

    init(url: URL? = nil) {
        let resolved = url ?? Self.defaultURL()
        self.url = resolved
        try? FileManager.default.createDirectory(
            at: resolved.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? Data(contentsOf: resolved) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let file = try? decoder.decode(FileFormat.self, from: data) {
                for entry in file.entries {
                    cache[entry.sha256] = entry
                }
            }
        }
    }

    static func defaultURL() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return appSupport
            .appending(path: "Voice2MD")
            .appending(path: "processed.json")
    }

    func seen(sha256: String) -> Entry? {
        cache[sha256]
    }

    func recent(limit: Int = 10) -> [Entry] {
        cache.values
            .filter { $0.status == .ok }
            .sorted { $0.processedAt > $1.processedAt }
            .prefix(limit)
            .map { $0 }
    }

    func all() -> [Entry] {
        cache.values.sorted { $0.processedAt > $1.processedAt }
    }

    func markDone(
        sha256: String,
        sourcePath: String,
        outputPath: String,
        model: String? = nil,
        whisperModel: String? = nil
    ) throws {
        cache[sha256] = Entry(
            sha256: sha256,
            sourcePath: sourcePath,
            outputPath: outputPath,
            processedAt: Date(),
            status: .ok,
            error: nil,
            model: model,
            whisperModel: whisperModel
        )
        try save()
    }

    func markFailed(
        sha256: String,
        sourcePath: String,
        error: String
    ) throws {
        cache[sha256] = Entry(
            sha256: sha256,
            sourcePath: sourcePath,
            outputPath: nil,
            processedAt: Date(),
            status: .failed,
            error: error,
            model: nil,
            whisperModel: nil
        )
        try save()
    }

    private func save() throws {
        let file = FileFormat(entries: cache.values.sorted { $0.processedAt < $1.processedAt })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: url, options: .atomic)
    }
}
