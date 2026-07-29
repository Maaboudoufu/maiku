import Foundation
import Testing

@testable import MaikuKit

private func makeStubbedLMStudio(completions: [StubOutcome]) -> (client: LMStudioClient, port: Int) {
    let port = StubRegistry.shared.register(Stub(completions: completions))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return (
        LMStudioClient(
            configuration: LMStudioConfiguration(
                baseURL: URL(string: "http://127.0.0.1:\(port)")!, modelID: "test-model"),
            session: URLSession(configuration: configuration)),
        port
    )
}

private let minimalOrganizedJSON = """
    {
      "title": "Launch Sync", "shortSummary": "Quick sync about launch prep.", "detailedSummary": "",
      "organizedSections": [], "keyTakeaways": [], "decisions": [], "actionItems": [],
      "openQuestions": [], "followUps": [], "quotes": [], "topics": [], "tags": ["launch"],
      "speakerSummary": []
    }
    """

private func minimalChunkJSON(_ label: String) -> String {
    """
    {"summary": "\(label)", "topics": [], "keyPoints": [], "decisions": [], "actionItems": [],
     "openQuestions": [], "quotes": [], "tags": []}
    """
}

@Suite("Organization pipeline")
struct OrganizationPipelineTests {

    private let recordingID = UUID()

    private func segment(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(
            recordingID: recordingID, startTime: start, endTime: end, text: text, isFinal: true, source: .final)
    }

    @Test("A short transcript that fits in one chunk goes straight through organizeTranscript")
    func singleChunkSkipsMapReduce() async throws {
        let (client, _) = makeStubbedLMStudio(
            completions: [.reply(status: 200, body: Fixture.completion(minimalOrganizedJSON))])
        let pipeline = OrganizationPipeline(lmStudio: client)
        let segments = [segment("Hello there.", 0, 2), segment("General Kenobi.", 2, 4)]

        let result = try await pipeline.organize(
            recordingID: recordingID, recordedAt: Date(timeIntervalSince1970: 0), durationSeconds: 4,
            segments: segments, speakers: [])

        #expect(result.title == "Launch Sync")
        // Only one completion was ever registered; if the pipeline had
        // called summarizeChunk or reduceChunkSummaries too, decoding a
        // whole-recording OrganizedRecording as a ChunkSummary would have
        // failed the request instead of returning cleanly.
    }

    @Test("A transcript forced into multiple chunks maps each one, then reduces once")
    func multiChunkMapsAndReduces() async throws {
        let (client, port) = makeStubbedLMStudio(completions: [
            .reply(status: 200, body: Fixture.completion(minimalChunkJSON("part one"))),
            .reply(status: 200, body: Fixture.completion(minimalChunkJSON("part two"))),
            .reply(status: 200, body: Fixture.completion(minimalOrganizedJSON)),
        ])
        let pipeline = OrganizationPipeline(lmStudio: client)
        // A tiny budget forces two chunks out of two short segments.
        let segments = [
            segment(String(repeating: "a", count: 40), 0, 2),
            segment(String(repeating: "b", count: 40), 2, 4),
        ]

        let result = try await pipeline.organize(
            recordingID: recordingID, recordedAt: Date(timeIntervalSince1970: 0), durationSeconds: 4,
            segments: segments, speakers: [], maxCharactersPerChunk: 45)

        #expect(result.title == "Launch Sync")
        #expect(StubRegistry.shared.completionCalls(port: port) == 3, "two chunk extractions plus one reduce")
    }

    @Test("Every path validates the result — a hallucinated reference does not survive the pipeline")
    func resultIsValidated() async throws {
        let realSegmentID = UUID()
        let hallucinatedJSON = """
            {
              "title": "Sync", "shortSummary": "x", "detailedSummary": "",
              "organizedSections": [], "keyTakeaways": [
                {"text": "invented", "sourceSegmentIDs": ["\(UUID().uuidString)"], "confidence": 0.9}
              ],
              "decisions": [], "actionItems": [], "openQuestions": [], "followUps": [],
              "quotes": [], "topics": [], "tags": [], "speakerSummary": []
            }
            """
        let (client, _) = makeStubbedLMStudio(
            completions: [.reply(status: 200, body: Fixture.completion(hallucinatedJSON))])
        let pipeline = OrganizationPipeline(lmStudio: client)

        let result = try await pipeline.organize(
            recordingID: recordingID, recordedAt: Date(timeIntervalSince1970: 0), durationSeconds: 2,
            segments: [
                TranscriptSegment(
                    id: realSegmentID, recordingID: recordingID, startTime: 0, endTime: 2,
                    text: "Real transcript content.", isFinal: true, source: .final)
            ], speakers: [])

        #expect(result.keyTakeaways.isEmpty, "a claim citing a segment id absent from this recording must be dropped")
    }
}
