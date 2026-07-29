import Foundation
import Testing

@testable import MaikuKit

@Suite("Recording exporter")
struct RecordingExporterTests {

    private static let recordingID = UUID()
    private static let speakerID = UUID()

    private static func makeContext() -> RecordingExportContext {
        let speaker = Speaker(id: speakerID, recordingID: recordingID, diarizerLabel: "1", customName: "Priya")
        let segments = [
            TranscriptSegment(
                recordingID: recordingID, speakerID: speakerID, startTime: 0, endTime: 2.5,
                text: "Let's get started.", isFinal: true, source: .final),
            TranscriptSegment(
                recordingID: recordingID, startTime: 2.5, endTime: 5, text: "Sounds good.",
                isFinal: true, source: .final),
        ]
        let organized = OrganizedRecording(
            title: "Launch Sync", shortSummary: "Quick sync about launch prep.",
            decisions: [Decision(text: "Ship Friday.")],
            actionItems: [ActionItem(task: "Send the doc", ownerText: "Priya")],
            openQuestions: [SourcedStatement(text: "Who owns QA?")],
            quotes: [
                ImportantQuote(
                    exactText: "Let's get started.", speakerID: speakerID,
                    segmentID: segments[0].id, startTime: 0, endTime: 2.5)
            ],
            tags: ["launch", "planning"])
        let recording = Recording(
            id: recordingID, title: "Launch Sync", status: .complete,
            recordingStartedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 5)
        return RecordingExportContext(
            recording: recording, speakers: [speaker], segments: segments, organized: organized)
    }

    @Test("Markdown includes every plan §11.2 section")
    func markdownIncludesRequiredSections() {
        let markdown = RecordingExporter.export(Self.makeContext(), as: .markdown)
        #expect(markdown.contains("# Launch Sync"))
        #expect(markdown.contains("## Summary"))
        #expect(markdown.contains("## Decisions"))
        #expect(markdown.contains("Ship Friday."))
        #expect(markdown.contains("## Action Items"))
        #expect(markdown.contains("Send the doc"))
        #expect(markdown.contains("## Open Questions"))
        #expect(markdown.contains("## Quotes"))
        #expect(markdown.contains("Priya"))
        #expect(markdown.contains("launch, planning"))
        #expect(markdown.contains("## Transcript"))
        #expect(markdown.contains("Let's get started."))
        #expect(markdown.contains("Sounds good."))
    }

    @Test("Plain text has no markdown syntax but keeps the content")
    func plainTextHasNoMarkdownSyntax() {
        let text = RecordingExporter.export(Self.makeContext(), as: .plainText)
        #expect(!text.contains("#"))
        #expect(!text.contains("**"))
        #expect(text.contains("Launch Sync"))
        #expect(text.contains("Ship Friday."))
        #expect(text.contains("TRANSCRIPT"))
    }

    @Test("JSON round-trips the organized notes and transcript")
    func jsonRoundTrips() throws {
        let json = RecordingExporter.export(Self.makeContext(), as: .json)
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode([String: AnyDecodableForTest].self, from: data)
        #expect(decoded["metadata"] != nil)
        #expect(decoded["organized"] != nil)
        #expect(decoded["transcript"] != nil)
        #expect(json.contains("Launch Sync"))
        #expect(json.contains("Ship Friday."))
    }

    @Test("SRT numbers cues sequentially with comma-decimal timestamps")
    func srtFormat() {
        let srt = RecordingExporter.export(Self.makeContext(), as: .srt)
        let expected = """
            1
            00:00:00,000 --> 00:00:02,500
            Priya: Let's get started.

            2
            00:00:02,500 --> 00:00:05,000
            Sounds good.
            """
        #expect(srt == expected)
    }

    @Test("VTT starts with WEBVTT and uses period-decimal timestamps")
    func vttFormat() {
        let vtt = RecordingExporter.export(Self.makeContext(), as: .vtt)
        let expected = """
            WEBVTT

            00:00:00.000 --> 00:00:02.500
            Priya: Let's get started.

            00:00:02.500 --> 00:00:05.000
            Sounds good.
            """
        #expect(vtt == expected)
    }

    @Test("Every format's file extension is distinct")
    func fileExtensionsAreDistinct() {
        let extensions = Set(ExportFormat.allCases.map(\.fileExtension))
        #expect(extensions.count == ExportFormat.allCases.count)
    }
}

/// Just enough to prove the JSON decodes as an object with the expected
/// top-level keys, without hand-modeling the whole export schema again.
private struct AnyDecodableForTest: Decodable {}
