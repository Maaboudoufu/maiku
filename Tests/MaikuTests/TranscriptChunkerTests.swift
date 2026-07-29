import Foundation
import Testing

@testable import MaikuKit

@Suite("Transcript chunker")
struct TranscriptChunkerTests {

    private func segment(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(recordingID: UUID(), startTime: start, endTime: end, text: text, isFinal: true, source: .final)
    }

    @Test("An empty transcript produces no chunks")
    func emptyTranscript() {
        #expect(TranscriptChunker.chunk([]).isEmpty)
    }

    @Test("A short transcript fits in exactly one chunk")
    func shortTranscriptFitsOneChunk() {
        let segments = [segment("Hello there.", 0, 2), segment("General Kenobi.", 2, 4)]
        let chunks = TranscriptChunker.chunk(segments, maxCharactersPerChunk: 6_000)
        #expect(chunks.count == 1)
        #expect(chunks[0].index == 0)
        #expect(chunks[0].segments.map(\.text) == ["Hello there.", "General Kenobi."])
    }

    @Test("Every segment appears in exactly one chunk's own content, never split mid-segment")
    func neverSplitsMidSegment() {
        let segments = (0..<20).map { i in
            segment(String(repeating: "word ", count: 20), TimeInterval(i * 5), TimeInterval(i * 5 + 4))
        }
        let chunks = TranscriptChunker.chunk(segments, maxCharactersPerChunk: 300, overlapSegments: 0)
        #expect(chunks.count > 1, "fixture should have forced more than one chunk")
        for chunk in chunks {
            for s in chunk.segments {
                #expect(s.text == String(repeating: "word ", count: 20), "no segment's text was altered or truncated")
            }
        }
    }

    @Test("Chunk indices are assigned in order starting from zero")
    func indicesAreSequential() {
        let segments = (0..<10).map { i in
            segment(String(repeating: "x", count: 500), TimeInterval(i * 10), TimeInterval(i * 10 + 8))
        }
        let chunks = TranscriptChunker.chunk(segments, maxCharactersPerChunk: 1_000, overlapSegments: 0)
        #expect(chunks.map(\.index) == Array(0..<chunks.count))
    }

    @Test("A budget exceeded mid-way starts a new chunk")
    func exceedingBudgetStartsNewChunk() {
        let segments = [
            segment(String(repeating: "a", count: 60), 0, 2),
            segment(String(repeating: "b", count: 60), 2, 4),
            segment(String(repeating: "c", count: 60), 4, 6),
        ]
        // Budget fits two segments (120 chars) but not three (180).
        let chunks = TranscriptChunker.chunk(segments, maxCharactersPerChunk: 130, overlapSegments: 0)
        #expect(chunks.count == 2)
        #expect(chunks[0].segments.map(\.text.first) == ["a", "b"])
        #expect(chunks[1].segments.map(\.text.first) == ["c"])
    }

    @Test("A single segment far larger than the whole budget still gets its own chunk, unsplit")
    func oversizedSegmentGetsItsOwnChunk() {
        let huge = segment(String(repeating: "z", count: 10_000), 0, 60)
        let chunks = TranscriptChunker.chunk([huge], maxCharactersPerChunk: 100)
        #expect(chunks.count == 1)
        #expect(chunks[0].segments.first?.text.count == 10_000)
    }

    @Test("Overlap carries the tail of one chunk into the start of the next")
    func overlapCarriesForward() {
        let segments = [
            segment(String(repeating: "a", count: 60), 0, 2),
            segment(String(repeating: "b", count: 60), 2, 4),
            segment(String(repeating: "c", count: 60), 4, 6),
        ]
        let chunks = TranscriptChunker.chunk(segments, maxCharactersPerChunk: 130, overlapSegments: 1)
        #expect(chunks.count == 2)
        // The last segment of chunk 0 ("b") reappears as the first of chunk 1.
        #expect(chunks[0].segments.map(\.text.first) == ["a", "b"])
        #expect(chunks[1].segments.map(\.text.first) == ["b", "c"])
    }

    @Test("A long silence gap ends a chunk early, once the chunk is already reasonably full")
    func silenceGapPrefersEarlyBreak() {
        // The silence-gap break only applies once a chunk is already at least
        // 3/5 of the budget (avoids fragmenting into many tiny chunks over
        // ordinary conversational pauses) — 46 characters against a 70-char
        // budget clears that 42-character floor.
        let segments = [
            segment("First topic, part one.", 0, 5),
            segment("First topic, part two.", 5, 10),
            segment("Second topic entirely.", 310, 315),
        ]
        let chunks = TranscriptChunker.chunk(
            segments, maxCharactersPerChunk: 70, overlapSegments: 0, silenceGapThreshold: 60)
        #expect(chunks.count == 2, "the 5-minute gap should have split the chunk once it was already full enough")
        #expect(chunks[0].segments.map(\.text) == ["First topic, part one.", "First topic, part two."])
        #expect(chunks[1].segments.map(\.text) == ["Second topic entirely."])
    }

    @Test("A short gap below the threshold does not force an early break")
    func shortGapDoesNotBreak() {
        let segments = [
            segment("First topic, part one.", 0, 5),
            segment("First topic, part two.", 6, 10),
        ]
        let chunks = TranscriptChunker.chunk(
            segments, maxCharactersPerChunk: 6_000, overlapSegments: 0, silenceGapThreshold: 60)
        #expect(chunks.count == 1)
    }

    @Test("Concatenating every chunk's segment ids, minus overlap duplicates, reconstructs the transcript")
    func chunksTogetherCoverEveryID() {
        let segments = (0..<15).map { i in
            segment("segment \(i)", TimeInterval(i * 3), TimeInterval(i * 3 + 2))
        }
        let chunks = TranscriptChunker.chunk(segments, maxCharactersPerChunk: 40, overlapSegments: 1)
        let coveredIDs = Set(chunks.flatMap { $0.segments.map(\.id) })
        #expect(coveredIDs == Set(segments.map(\.id)), "every original segment must appear somewhere")
    }
}
