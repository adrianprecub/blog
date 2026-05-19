import Foundation

struct RenderedMarkdown: Equatable, Sendable {
    let filename: String
    let body: String
}

struct PipelineSourceInfo: Sendable {
    let originalFilename: String
    let sha256: String
    let format: String
    let transcribedWith: String
    let aiModel: String?
}

enum MarkdownRenderer {
    static func render(
        extraction: ExtractionResult,
        media: MediaMetadata,
        source: PipelineSourceInfo,
        processingDate: Date = Date(),
        timeZone: TimeZone = .current
    ) -> RenderedMarkdown {
        let nameFmt = DateFormatter()
        nameFmt.locale = Locale(identifier: "en_US_POSIX")
        nameFmt.timeZone = timeZone
        nameFmt.dateFormat = "yyyy-MM-dd_HHmm"
        let datePart = nameFmt.string(from: media.recordingDate)
        let slug = Slug.make(extraction.title)
        let filename = "\(datePart)_\(slug).md"

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = timeZone

        var body = "---\n"
        body += "title: \(yamlString(extraction.title))\n"
        body += "recording_date: \(iso.string(from: media.recordingDate))\n"
        body += "processing_date: \(iso.string(from: processingDate))\n"
        body += "source_media: \(yamlString(source.originalFilename))\n"
        body += "source_format: \(source.format)\n"
        body += "source_sha256: \(source.sha256)\n"
        body += "duration_sec: \(Int(media.durationSec.rounded()))\n"
        body += "transcribed_with: \(yamlString(source.transcribedWith))\n"
        body += "model: \(yamlString(source.aiModel ?? ""))\n"
        if extraction.topics.isEmpty {
            body += "tags: []\n"
        } else {
            body += "tags:\n"
            for tag in extraction.topics {
                body += "  - \(yamlString(tag))\n"
            }
        }
        body += "---\n\n"

        body += "## Summary\n\n\(extraction.summary)\n\n"

        body += "## Key Ideas\n\n"
        if extraction.keyIdeas.isEmpty {
            body += "_None._\n\n"
        } else {
            for idea in extraction.keyIdeas {
                body += "- \(idea)\n"
            }
            body += "\n"
        }

        body += "## Topics\n\n"
        if extraction.topics.isEmpty {
            body += "_None._\n\n"
        } else {
            body += extraction.topics.map { "`\($0)`" }.joined(separator: ", ") + "\n\n"
        }

        body += "## Action Items\n\n"
        if extraction.actionItems.isEmpty {
            body += "_None._\n\n"
        } else {
            for item in extraction.actionItems {
                var line = "- [ ] \(item.task)"
                if let owner = item.owner, !owner.isEmpty {
                    line += " — \(owner)"
                }
                if let due = item.due, !due.isEmpty {
                    line += " (\(due))"
                }
                body += "\(line)\n"
            }
            body += "\n"
        }

        body += "## Entities\n\n"
        body += "- **People:** \(joinOrEmpty(extraction.entities.people))\n"
        body += "- **Places:** \(joinOrEmpty(extraction.entities.places))\n"
        body += "- **Organizations:** \(joinOrEmpty(extraction.entities.orgs))\n\n"

        body += "## Cleaned Transcript\n\n\(extraction.cleanedTranscript)\n"

        return RenderedMarkdown(filename: filename, body: body)
    }

    static func renderPlain(
        transcript: String,
        media: MediaMetadata,
        source: PipelineSourceInfo,
        processingDate: Date = Date(),
        timeZone: TimeZone = .current
    ) -> RenderedMarkdown {
        let nameFmt = DateFormatter()
        nameFmt.locale = Locale(identifier: "en_US_POSIX")
        nameFmt.timeZone = timeZone
        nameFmt.dateFormat = "yyyy-MM-dd_HHmm"
        let datePart = nameFmt.string(from: media.recordingDate)

        let stem = (source.originalFilename as NSString).deletingPathExtension
        let title = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = Slug.make(stem)
        let filename = "\(datePart)_\(slug).md"

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = timeZone

        var body = "---\n"
        body += "title: \(yamlString(title))\n"
        body += "recording_date: \(iso.string(from: media.recordingDate))\n"
        body += "processing_date: \(iso.string(from: processingDate))\n"
        body += "source_media: \(yamlString(source.originalFilename))\n"
        body += "source_format: \(source.format)\n"
        body += "source_sha256: \(source.sha256)\n"
        body += "duration_sec: \(Int(media.durationSec.rounded()))\n"
        body += "transcribed_with: \(yamlString(source.transcribedWith))\n"
        body += "---\n\n"

        body += "# \(title)\n\n"
        body += "\(transcript.trimmingCharacters(in: .whitespacesAndNewlines))\n"

        return RenderedMarkdown(filename: filename, body: body)
    }

    private static func yamlString(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'"
    }

    private static func joinOrEmpty(_ xs: [String]) -> String {
        xs.isEmpty ? "_none_" : xs.joined(separator: ", ")
    }
}
