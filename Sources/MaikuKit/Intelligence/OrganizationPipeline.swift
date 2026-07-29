import Foundation

/// Orchestrates plan §7's full organization pass: chunk, map, reduce,
/// validate. `RecordingCoordinator` calls this instead of `LMStudioClient`
/// directly, so the chunking and validation logic lives in one place
/// regardless of which coordinator method needs a recording organized
/// (finalization, "Retry Processing", "Retry Organization").
public struct OrganizationPipeline: Sendable {
    private let lmStudio: LMStudioClient

    public init(lmStudio: LMStudioClient) {
        self.lmStudio = lmStudio
    }

    /// A recording short enough for `TranscriptChunker` to produce a single
    /// chunk skips straight to `organizeTranscript` — map-reducing one chunk
    /// through itself would just be a second, wasted LM Studio round trip
    /// for no benefit plan §7.2 asks for. Every path ends through
    /// `OutputValidator`, so a hallucinated reference cannot reach the
    /// database via either one.
    /// - Parameter maxCharactersPerChunk: plan §7.1's "configurable safe
    ///   input budget" — passed straight through to `TranscriptChunker`.
    public func organize(
        recordingID: UUID, recordedAt: Date, durationSeconds: TimeInterval,
        segments: [TranscriptSegment], speakers: [Speaker], maxCharactersPerChunk: Int = 6_000
    ) async throws -> OrganizedRecording {
        let chunks = TranscriptChunker.chunk(segments, maxCharactersPerChunk: maxCharactersPerChunk)
        let organized: OrganizedRecording

        if chunks.count <= 1 {
            organized = try await lmStudio.organizeTranscript(
                OrganizationRequest(
                    recordingID: recordingID, recordedAt: recordedAt, durationSeconds: durationSeconds,
                    segments: segments, speakers: speakers))
        } else {
            // Sequential, not concurrent: a single local LM Studio server
            // processes one inference at a time regardless, and overlapping
            // requests would only queue behind each other while making
            // failures harder to attribute to a specific chunk.
            var chunkSummaries: [ChunkSummary] = []
            for chunk in chunks {
                let summary = try await lmStudio.summarizeChunk(
                    ChunkSummaryRequest(
                        chunkIndex: chunk.index, chunkCount: chunks.count, segments: chunk.segments,
                        speakers: speakers))
                chunkSummaries.append(summary)
            }
            organized = try await lmStudio.reduceChunkSummaries(
                ReduceRequest(
                    recordingID: recordingID, recordedAt: recordedAt, durationSeconds: durationSeconds,
                    chunkSummaries: chunkSummaries, speakers: speakers))
        }

        return OutputValidator.validate(organized, segments: segments, speakers: speakers)
    }
}
