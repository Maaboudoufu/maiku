import Foundation

/// Plan §11.2's five formats. `Export must not contain hidden diagnostics or
/// internal prompts` — every function here only ever touches what the user
/// can already see on the Recording Detail screen.
public enum ExportFormat: String, CaseIterable, Sendable, Identifiable {
    case markdown
    case plainText
    case json
    case srt
    case vtt

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .markdown: "Markdown"
        case .plainText: "Plain Text"
        case .json: "JSON"
        case .srt: "SRT"
        case .vtt: "VTT"
        }
    }

    public var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .plainText: "txt"
        case .json: "json"
        case .srt: "srt"
        case .vtt: "vtt"
        }
    }
}

/// Everything one recording's export can draw from — a plain snapshot
/// rather than a live repository handle, so exporting never races a
/// concurrent edit.
public struct RecordingExportContext: Sendable {
    public var recording: Recording
    public var speakers: [Speaker]
    public var segments: [TranscriptSegment]
    public var organized: OrganizedRecording?

    public init(
        recording: Recording, speakers: [Speaker], segments: [TranscriptSegment],
        organized: OrganizedRecording?
    ) {
        self.recording = recording
        self.speakers = speakers
        self.segments = segments
        self.organized = organized
    }

    fileprivate var orderedSegments: [TranscriptSegment] {
        segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.startTime < $1.startTime }
    }

    fileprivate func speakerName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return speakers.first { $0.id == id }?.displayName
    }
}

public enum RecordingExporter {
    public static func export(_ context: RecordingExportContext, as format: ExportFormat) -> String {
        switch format {
        case .markdown: markdown(context)
        case .plainText: plainText(context)
        case .json: json(context)
        case .srt: srt(context)
        case .vtt: vtt(context)
        }
    }

    // MARK: - Markdown

    private static func markdown(_ c: RecordingExportContext) -> String {
        var lines: [String] = []
        let title = c.recording.title.isEmpty ? "Untitled Recording" : c.recording.title
        lines.append("# \(title)")
        lines.append("")
        lines.append(
            "**Recorded:** \(Self.dateFormatter.string(from: c.recording.recordingStartedAt))  "
                + "**Duration:** \(Self.clock(c.recording.durationSeconds))  "
                + "**Status:** \(c.recording.status.rawValue)")

        if let organized = c.organized {
            if !organized.tags.isEmpty {
                lines.append("**Tags:** \(organized.tags.joined(separator: ", "))")
            }
            lines.append("")
            if !organized.shortSummary.isEmpty {
                lines.append("## Summary")
                lines.append(organized.shortSummary)
                lines.append("")
            }
            if !organized.detailedSummary.isEmpty {
                lines.append(organized.detailedSummary)
                lines.append("")
            }
            if !organized.organizedSections.isEmpty {
                lines.append("## Organized Notes")
                for section in organized.organizedSections {
                    lines.append("### \(section.heading)")
                    lines.append(section.body)
                    lines.append("")
                }
            }
            if !organized.keyTakeaways.isEmpty {
                lines.append("## Key Takeaways")
                lines.append(contentsOf: organized.keyTakeaways.map { "- \($0.text)" })
                lines.append("")
            }
            if !organized.decisions.isEmpty {
                lines.append("## Decisions")
                lines.append(
                    contentsOf: organized.decisions.map { decision in
                        let rationale = decision.rationale.map { " (\($0))" } ?? ""
                        return "- \(decision.text)\(rationale)"
                    })
                lines.append("")
            }
            if !organized.actionItems.isEmpty {
                lines.append("## Action Items")
                lines.append(contentsOf: organized.actionItems.map(Self.actionItemLine))
                lines.append("")
            }
            if !organized.openQuestions.isEmpty {
                lines.append("## Open Questions")
                lines.append(contentsOf: organized.openQuestions.map { "- \($0.text)" })
                lines.append("")
            }
            if !organized.quotes.isEmpty {
                lines.append("## Quotes")
                for quote in organized.quotes {
                    let speaker = c.speakerName(quote.speakerID) ?? "Unknown speaker"
                    lines.append("> \"\(quote.exactText)\" — \(speaker) (\(Self.clock(quote.startTime)))")
                }
                lines.append("")
            }
        }

        lines.append("## Transcript")
        for segment in c.orderedSegments {
            let speaker = c.speakerName(segment.speakerID) ?? "Unknown speaker"
            lines.append("**[\(Self.clock(segment.startTime))] \(speaker):** \(segment.text)")
        }

        return lines.joined(separator: "\n")
    }

    private static func actionItemLine(_ item: ActionItem) -> String {
        var line = "- [\(item.status == .done ? "x" : " ")] \(item.task)"
        if let owner = item.ownerText { line += " (\(owner))" }
        if let due = item.dueDateISO8601 { line += " — due \(due)" }
        return line
    }

    // MARK: - Plain text

    private static func plainText(_ c: RecordingExportContext) -> String {
        var lines: [String] = []
        let title = c.recording.title.isEmpty ? "Untitled Recording" : c.recording.title
        lines.append(title)
        lines.append(String(repeating: "=", count: title.count))
        lines.append("")
        lines.append(
            "Recorded: \(Self.dateFormatter.string(from: c.recording.recordingStartedAt)) · "
                + "Duration: \(Self.clock(c.recording.durationSeconds)) · Status: \(c.recording.status.rawValue)")

        if let organized = c.organized {
            if !organized.tags.isEmpty {
                lines.append("Tags: \(organized.tags.joined(separator: ", "))")
            }
            lines.append("")
            if !organized.shortSummary.isEmpty {
                lines.append("SUMMARY")
                lines.append(organized.shortSummary)
                lines.append("")
            }
            if !organized.decisions.isEmpty {
                lines.append("DECISIONS")
                lines.append(contentsOf: organized.decisions.map { "- \($0.text)" })
                lines.append("")
            }
            if !organized.actionItems.isEmpty {
                lines.append("ACTION ITEMS")
                lines.append(contentsOf: organized.actionItems.map { "- \($0.task)" })
                lines.append("")
            }
            if !organized.openQuestions.isEmpty {
                lines.append("OPEN QUESTIONS")
                lines.append(contentsOf: organized.openQuestions.map { "- \($0.text)" })
                lines.append("")
            }
        }

        lines.append("TRANSCRIPT")
        for segment in c.orderedSegments {
            let speaker = c.speakerName(segment.speakerID) ?? "Unknown speaker"
            lines.append("[\(Self.clock(segment.startTime))] \(speaker): \(segment.text)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - JSON

    private struct ExportDocument: Encodable {
        struct Metadata: Encodable {
            let id: UUID
            let title: String
            let status: String
            let recordingStartedAt: Date
            let recordingEndedAt: Date?
            let durationSeconds: TimeInterval
        }
        struct Segment: Encodable {
            let startTime: TimeInterval
            let endTime: TimeInterval
            let speaker: String?
            let text: String
        }
        let metadata: Metadata
        let organized: OrganizedRecording?
        let transcript: [Segment]
    }

    private static func json(_ c: RecordingExportContext) -> String {
        let document = ExportDocument(
            metadata: .init(
                id: c.recording.id, title: c.recording.title, status: c.recording.status.rawValue,
                recordingStartedAt: c.recording.recordingStartedAt,
                recordingEndedAt: c.recording.recordingEndedAt,
                durationSeconds: c.recording.durationSeconds),
            organized: c.organized,
            transcript: c.orderedSegments.map { segment in
                .init(
                    startTime: segment.startTime, endTime: segment.endTime,
                    speaker: c.speakerName(segment.speakerID), text: segment.text)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(document), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    // MARK: - Subtitles

    private static func srt(_ c: RecordingExportContext) -> String {
        c.orderedSegments.enumerated().map { index, segment in
            let speaker = c.speakerName(segment.speakerID)
            let text = speaker.map { "\($0): \(segment.text)" } ?? segment.text
            return """
                \(index + 1)
                \(Self.timestamp(segment.startTime, decimalSeparator: ",")) --> \(Self.timestamp(segment.endTime, decimalSeparator: ","))
                \(text)
                """
        }.joined(separator: "\n\n")
    }

    private static func vtt(_ c: RecordingExportContext) -> String {
        let cues = c.orderedSegments.map { segment -> String in
            let speaker = c.speakerName(segment.speakerID)
            let text = speaker.map { "\($0): \(segment.text)" } ?? segment.text
            return """
                \(Self.timestamp(segment.startTime, decimalSeparator: ".")) --> \(Self.timestamp(segment.endTime, decimalSeparator: "."))
                \(text)
                """
        }
        return (["WEBVTT"] + cues).joined(separator: "\n\n")
    }

    // MARK: - Formatting helpers

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// `mm:ss`, or `h:mm:ss` past an hour — matches the player's own clock.
    private static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// `HH:MM:SS,mmm` (SRT) or `HH:MM:SS.mmm` (VTT) — both fixed-width and
    /// always hour-padded, unlike `clock(_:)`, since that's what both subtitle
    /// formats require regardless of a recording's actual length.
    private static func timestamp(_ seconds: TimeInterval, decimalSeparator: String) -> String {
        let clamped = max(0, seconds)
        let hours = Int(clamped) / 3600
        let minutes = (Int(clamped) % 3600) / 60
        let secs = Int(clamped) % 60
        let millis = Int((clamped - clamped.rounded(.down)) * 1000)
        return String(format: "%02d:%02d:%02d\(decimalSeparator)%03d", hours, minutes, secs, millis)
    }
}
