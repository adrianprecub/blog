import Foundation

/// Extracts the transcript that Apple Voice Memos (iOS 18 / macOS Sequoia and later)
/// embeds inside .m4a files at the MP4 atom path `moov/trak/udta/tsrp`. Payload is a
/// JSON object of shape `{"attributedString": {"runs": [...]}}`. Strings inside `runs`
/// are concatenated; non-string entries (attribute deltas) are ignored.
///
/// Returns nil for files without the atom (older recordings, non-Apple-Memos m4a).
enum AppleTranscriptExtractor {
    static func extract(from url: URL) -> String? {
        guard let payload = readAtomPayload(path: ["moov", "trak", "udta", "tsrp"], in: url) else {
            return nil
        }
        return parseTsrpPayload(payload)
    }

    static func readAtomPayload(path: [String], in url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return findAtom(path: path, in: data, range: 0..<data.count)
    }

    static func parseTsrpPayload(_ payload: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        let raw = root["attributedString"]
        let extracted: String
        if let dict = raw as? [String: Any], let runs = dict["runs"] as? [Any] {
            extracted = runs.compactMap { $0 as? String }.joined()
        } else if let str = raw as? String {
            extracted = str
        } else {
            return nil
        }
        let trimmed = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func findAtom(path: [String], in data: Data, range: Range<Int>) -> Data? {
        guard let firstName = path.first else {
            return data.subdata(in: range)
        }
        var cursor = range.lowerBound
        while cursor + 8 <= range.upperBound {
            guard let size32 = data.readUInt32BE(at: cursor) else { return nil }
            let typeBytes = data.subdata(in: (cursor + 4)..<(cursor + 8))
            let type = String(data: typeBytes, encoding: .ascii) ?? ""

            let actualSize: Int
            let headerSize: Int
            if size32 == 1 {
                guard cursor + 16 <= range.upperBound,
                      let size64 = data.readUInt64BE(at: cursor + 8) else { return nil }
                actualSize = Int(size64)
                headerSize = 16
            } else if size32 == 0 {
                actualSize = range.upperBound - cursor
                headerSize = 8
            } else {
                actualSize = Int(size32)
                headerSize = 8
            }

            guard actualSize >= headerSize, cursor + actualSize <= range.upperBound else {
                return nil
            }
            let payloadStart = cursor + headerSize
            let atomEnd = cursor + actualSize

            if type == firstName {
                if let found = findAtom(
                    path: Array(path.dropFirst()),
                    in: data,
                    range: payloadStart..<atomEnd
                ) {
                    return found
                }
            }

            cursor = atomEnd
            if actualSize == 0 { break }
        }
        return nil
    }
}

private extension Data {
    func readUInt32BE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return withUnsafeBytes { buf -> UInt32 in
            let bytes = buf.bindMemory(to: UInt8.self)
            let b0 = UInt32(bytes[offset])
            let b1 = UInt32(bytes[offset + 1])
            let b2 = UInt32(bytes[offset + 2])
            let b3 = UInt32(bytes[offset + 3])
            return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
    }

    func readUInt64BE(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        return withUnsafeBytes { buf -> UInt64 in
            let bytes = buf.bindMemory(to: UInt8.self)
            var result: UInt64 = 0
            for i in 0..<8 {
                result = (result << 8) | UInt64(bytes[offset + i])
            }
            return result
        }
    }
}
