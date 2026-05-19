import Foundation
import AVFoundation

struct MediaMetadata: Sendable, Equatable {
    let recordingDate: Date
    let durationSec: Double
    let sourceFormat: String
}

enum MediaMetadataReader {
    static func read(_ url: URL) async -> MediaMetadata {
        let asset = AVURLAsset(url: url)

        let dateFromAsset = await creationDate(from: asset)
        let recordingDate = dateFromAsset
            ?? fileModificationDate(url)
            ?? Date()

        let duration: Double
        do {
            let cmTime = try await asset.load(.duration)
            let s = CMTimeGetSeconds(cmTime)
            duration = s.isFinite ? max(0, s) : 0
        } catch {
            duration = 0
        }

        return MediaMetadata(
            recordingDate: recordingDate,
            durationSec: duration,
            sourceFormat: url.pathExtension.lowercased()
        )
    }

    private static func creationDate(from asset: AVAsset) async -> Date? {
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        for item in metadata where item.commonKey == .commonKeyCreationDate {
            if let date = try? await item.load(.dateValue) {
                return date
            }
            if let str = try? await item.load(.stringValue), let parsed = parseDate(str) {
                return parsed
            }
        }
        return nil
    }

    private static func parseDate(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: s) { return d }
        plain.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: s)
    }

    private static func fileModificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
