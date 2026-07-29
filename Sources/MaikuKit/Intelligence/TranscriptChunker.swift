import Foundation

/// Splits a transcript into chunks small enough to send to LM Studio safely
/// (plan §7.1). Pure and dependency-free — no network, no persistence — so
/// it is exhaustively testable without a model or a database.
public enum TranscriptChunker {

    public struct Chunk: Sendable, Equatable {
        public var index: Int
        public var segments: [TranscriptSegment]
    }

    /// - Parameters:
    ///   - segments: must already be in chronological order.
    ///   - maxCharactersPerChunk: the "configurable safe input budget" plan
    ///     §7.1 asks for. Characters rather than a real tokenizer count — a
    ///     token count would need a tokenizer dependency for what is, at the
    ///     safety margins this defaults to, an approximation either way.
    ///   - overlapSegments: segments repeated at the start of the next chunk,
    ///     so a claim spanning a chunk boundary still has both sides visible
    ///     to whichever chunk extracts it.
    ///   - silenceGapThreshold: a gap at least this long between two segments
    ///     is treated as a natural break — preferred over the hard character
    ///     ceiling once a chunk is already reasonably full.
    /// - Returns: at least one chunk when `segments` is non-empty, in order.
    ///   Never splits inside a single segment; a segment longer than the
    ///   whole budget gets its own oversized chunk rather than being cut
    ///   (plan §7.1: "Do not split in the middle of a transcript segment
    ///   unless a single segment is unusually large").
    public static func chunk(
        _ segments: [TranscriptSegment],
        maxCharactersPerChunk: Int = 6_000,
        overlapSegments: Int = 1,
        silenceGapThreshold: TimeInterval = 2.0
    ) -> [Chunk] {
        guard !segments.isEmpty else { return [] }

        var chunks: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        var currentLength = 0

        for (offset, segment) in segments.enumerated() {
            let segmentLength = segment.text.count
            let gapBeforeThis = offset > 0 ? segment.startTime - segments[offset - 1].endTime : 0
            let wouldExceedBudget = !current.isEmpty && currentLength + segmentLength > maxCharactersPerChunk
            let atGoodBreakPoint =
                !current.isEmpty && currentLength >= maxCharactersPerChunk * 3 / 5
                && gapBeforeThis >= silenceGapThreshold

            if wouldExceedBudget || atGoodBreakPoint {
                chunks.append(current)
                let overlap = current.suffix(overlapSegments)
                current = Array(overlap)
                currentLength = current.reduce(0) { $0 + $1.text.count }
            }

            current.append(segment)
            currentLength += segmentLength
        }
        chunks.append(current)

        return chunks.enumerated().map { Chunk(index: $0, segments: $1) }
    }
}
