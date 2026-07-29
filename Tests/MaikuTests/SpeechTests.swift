import Foundation
import Testing

@testable import MaikuKit

@Suite("Transcript token sanitizer")
struct TranscriptTokenSanitizerTests {

    @Test("The exact string measured in the Milestone 0 spike is fully cleaned")
    func exactSpikeString() {
        let raw = "<|startoftranscript|><|0.00|> Good morning everyone<|4.16|>"
        #expect(TranscriptTokenSanitizer.clean(raw) == "Good morning everyone")
    }

    @Test("Multiple tokens throughout a sentence are all removed")
    func multipleTokens() {
        let raw = "<|en|><|transcribe|><|notimestamps|>Thanks.<|4.16|> I'll<|5.00|> own it.<|endoftext|>"
        #expect(TranscriptTokenSanitizer.clean(raw) == "Thanks. I'll own it.")
    }

    @Test("Plain text with no tokens is returned unchanged apart from whitespace")
    func plainText() {
        #expect(TranscriptTokenSanitizer.clean("Hello there") == "Hello there")
    }

    @Test("Interior and leading/trailing whitespace collapses to single spaces")
    func whitespaceCollapse() {
        #expect(TranscriptTokenSanitizer.clean("  Hello   there  \n") == "Hello there")
    }

    @Test("An unterminated angle bracket is left alone, not silently deleted")
    func unterminatedBracket() {
        #expect(TranscriptTokenSanitizer.clean("5 < 10 and 10 > 5") == "5 < 10 and 10 > 5")
    }

    @Test("A token-like string containing whitespace is not treated as a token")
    func tokenWithWhitespaceIsNotAToken() {
        #expect(TranscriptTokenSanitizer.clean("<| not a token |>") == "<| not a token |>")
    }

    @Test("An empty string cleans to an empty string")
    func emptyString() {
        #expect(TranscriptTokenSanitizer.clean("") == "")
    }

    @Test("A string that is only tokens cleans to empty")
    func onlyTokens() {
        #expect(TranscriptTokenSanitizer.clean("<|startoftranscript|><|en|><|transcribe|><|0.00|>") == "")
    }
}

@Suite("Speaker alignment")
struct SpeakerAlignmentServiceTests {

    private func segment(_ start: TimeInterval, _ end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(recordingID: UUID(), startTime: start, endTime: end, text: "x")
    }

    private func turn(_ label: String, _ start: TimeInterval, _ end: TimeInterval) -> SpeakerTurn {
        SpeakerTurn(diarizerLabel: label, startTime: start, endTime: end)
    }

    @Test("Clean alternation assigns each segment its own speaker")
    func cleanAlternation() {
        let segments = [segment(0, 2), segment(2, 4), segment(4, 6)]
        let turns = [turn("1", 0, 2), turn("2", 2, 4), turn("1", 4, 6)]
        #expect(SpeakerAlignmentService.labels(for: segments, turns: turns) == ["1", "2", "1"])
    }

    @Test("A segment resolves to whichever speaker holds more of its duration")
    func overlappingTurnsResolveByCoverage() {
        // Segment 0–4 is mostly turn "1" (0–3) with a brief overlap from "2" (3–4).
        let segments = [segment(0, 4)]
        let turns = [turn("1", 0, 3), turn("2", 3, 4)]
        #expect(SpeakerAlignmentService.labels(for: segments, turns: turns) == ["1"])
    }

    @Test("A spurious sub-threshold flip between the same voice is smoothed away")
    func spuriousFlipIsSmoothed() {
        // "1" for 0–3, a 0.2s blip of "2", then "1" resumes for 3.2–6 — the
        // blip must not survive, and the segment spanning it stays "1".
        let segments = [segment(0, 6)]
        let turns = [turn("1", 0, 3), turn("2", 3, 3.2), turn("1", 3.2, 6)]
        #expect(SpeakerAlignmentService.labels(for: segments, turns: turns) == ["1"])
    }

    @Test("A flip between two different voices, long enough to be real, is not smoothed")
    func genuineFlipSurvives() {
        let segments = [segment(0, 2), segment(2, 4), segment(4, 6)]
        let turns = [turn("1", 0, 2), turn("3", 2, 4), turn("2", 4, 6)]
        #expect(SpeakerAlignmentService.labels(for: segments, turns: turns) == ["1", "3", "2"])
    }

    @Test("A segment with no covering turn resolves to nil, never a guess")
    func uncoveredSegmentIsNil() {
        let segments = [segment(10, 12)]
        let turns = [turn("1", 0, 2)]
        #expect(SpeakerAlignmentService.labels(for: segments, turns: turns) == [nil])
    }

    @Test("An empty turn list leaves every segment unlabelled")
    func emptyTurnsYieldsAllNil() {
        let segments = [segment(0, 2), segment(2, 4)]
        #expect(SpeakerAlignmentService.labels(for: segments, turns: []) == [nil, nil])
    }

    @Test("align(_:to:speakerIDs:) resolves labels to speaker ids, leaving unmapped labels nil")
    func alignResolvesSpeakerIDs() {
        let knownID = UUID()
        let segments = [segment(0, 2), segment(2, 4)]
        let turns = [turn("1", 0, 2), turn("2", 2, 4)]
        let aligned = SpeakerAlignmentService.align(segments, to: turns, speakerIDs: ["1": knownID])
        #expect(aligned.map(\.speakerID) == [knownID, nil])
    }
}

@Suite("Streaming transcript merge")
struct StreamingMergeTests {

    private typealias Segment = StreamingMerge.Segment

    @Test("Segments ending before the unstable tail become newly stable")
    func segmentsBecomeStable() {
        let outcome = StreamingMerge.merge(
            segments: [Segment(start: 0, end: 3, text: "hello there")],
            previousStableBoundary: 0, windowEndTime: 6, unstableTail: 2)
        #expect(outcome.newStableBoundary == 4)
        #expect(outcome.newlyStable.map(\.text) == ["hello there"])
        #expect(outcome.unstableText.isEmpty)
    }

    @Test("Segments inside the unstable tail are reported as unstable text, not emitted as stable")
    func segmentsWithinTailStayUnstable() {
        let outcome = StreamingMerge.merge(
            segments: [Segment(start: 4, end: 5.5, text: "still forming")],
            previousStableBoundary: 0, windowEndTime: 6, unstableTail: 2)
        #expect(outcome.newlyStable.isEmpty)
        #expect(outcome.unstableText == "still forming")
    }

    @Test("A segment already covered by the previous boundary is not re-emitted")
    func alreadyStableSegmentsAreNotDuplicated() {
        // Re-transcribing the whole window returns this segment again, but it
        // was already emitted by an earlier flush and must not come back.
        let outcome = StreamingMerge.merge(
            segments: [Segment(start: 0, end: 2, text: "already emitted")],
            previousStableBoundary: 3, windowEndTime: 6, unstableTail: 2)
        #expect(outcome.newlyStable.isEmpty)
    }

    @Test("The stable boundary never moves backward even if the window shrinks")
    func boundaryNeverRegresses() {
        let outcome = StreamingMerge.merge(
            segments: [], previousStableBoundary: 5, windowEndTime: 5.5, unstableTail: 2)
        #expect(outcome.newStableBoundary == 5)
    }

    @Test("A zero unstable tail (final flush) treats everything remaining as stable")
    func finalFlushStabilisesEverything() {
        let outcome = StreamingMerge.merge(
            segments: [Segment(start: 4, end: 6, text: "right at the end")],
            previousStableBoundary: 4, windowEndTime: 6, unstableTail: 0)
        #expect(outcome.newlyStable.map(\.text) == ["right at the end"])
        #expect(outcome.unstableText.isEmpty)
        #expect(outcome.newStableBoundary == 6)
    }

    @Test("Multiple newly-stable segments are returned in chronological order")
    func multipleSegmentsOrdered() {
        let outcome = StreamingMerge.merge(
            segments: [
                Segment(start: 2, end: 3, text: "second"),
                Segment(start: 0, end: 1, text: "first"),
            ],
            previousStableBoundary: 0, windowEndTime: 5, unstableTail: 2)
        #expect(outcome.newlyStable.map(\.text) == ["first", "second"])
    }
}

@Suite("Streaming diarization turn merge")
struct DiarizerMergeTurnsTests {

    private func turn(_ label: String, _ start: TimeInterval, _ end: TimeInterval) -> SpeakerTurn {
        SpeakerTurn(diarizerLabel: label, startTime: start, endTime: end)
    }

    @Test("Turns entirely before the window start are kept as settled history")
    func settledTurnsAreKept() {
        let settled = [turn("1", 0, 3), turn("2", 3, 5)]
        let merged = FluidAudioDiarizer.mergeTurns(
            settled: settled, windowTurns: [turn("1", 5, 8)], windowStartTime: 5)
        #expect(merged.map(\.diarizerLabel) == ["1", "2", "1"])
        #expect(merged.map(\.endTime) == [3, 5, 8])
    }

    @Test("A settled turn overlapping the new window is replaced, not duplicated")
    func overlappingSettledTurnIsReplaced() {
        // The old turn for [4, 6) is stale — a later flush re-diarized that
        // span with more context and produced a different boundary.
        let settled = [turn("1", 0, 4), turn("2", 4, 6)]
        let merged = FluidAudioDiarizer.mergeTurns(
            settled: settled, windowTurns: [turn("2", 4.5, 7)], windowStartTime: 4)
        #expect(merged.map(\.diarizerLabel) == ["1", "2"])
        #expect(merged.map(\.startTime) == [0, 4.5])
    }

    @Test("An empty settled history plus a fresh window is just the window")
    func emptySettledHistory() {
        let merged = FluidAudioDiarizer.mergeTurns(
            settled: [], windowTurns: [turn("1", 0, 3)], windowStartTime: 0)
        #expect(merged.map(\.diarizerLabel) == ["1"])
    }

    @Test("An empty window leaves settled history untouched")
    func emptyWindowKeepsSettled() {
        let settled = [turn("1", 0, 3)]
        let merged = FluidAudioDiarizer.mergeTurns(settled: settled, windowTurns: [], windowStartTime: 10)
        #expect(merged == settled)
    }
}
