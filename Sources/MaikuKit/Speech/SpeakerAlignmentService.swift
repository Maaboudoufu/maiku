import Foundation

/// Attaches speakers to transcript segments (plan §6.4, §6.5 step 5).
///
/// Deliberately pure and free of any speech dependency: the Milestone 0 spike
/// measured diarizer boundaries drifting more than a second against Whisper's
/// segment times, so this is the piece that has to be exhaustively testable
/// without a model, a microphone, or a file.
public enum SpeakerAlignmentService {

    /// A turn shorter than this, with the same voice on both sides of it, is
    /// diarizer jitter rather than someone speaking. Absorbing it is the
    /// deterministic smoothing rule plan §6.4 asks for.
    ///
    /// ponytail: one fixed threshold, no confidence weighting. Real
    /// back-channels ("mm-hm") under half a second are erased along with the
    /// jitter. Upgrade path is to weight by `SpeakerTurn.quality` and keep
    /// short turns whose quality is high.
    public static let minimumTurnDuration: TimeInterval = 0.5

    /// Diarizer label per segment, in the order the segments were given.
    ///
    /// `nil` where no turn covers the segment at all — an unlabelled line is
    /// honest, a guessed one is not.
    public static func labels(
        for segments: [TranscriptSegment], turns: [SpeakerTurn]
    ) -> [String?] {
        let smoothed = smoothing(turns)
        guard !smoothed.isEmpty else { return Array(repeating: nil, count: segments.count) }
        return segments.map { dominantLabel(for: $0, in: smoothed) }
    }

    /// `labels(for:turns:)` applied to the segments, resolving labels through
    /// `speakerIDs`. A label with no speaker row leaves `speakerID` nil.
    public static func align(
        _ segments: [TranscriptSegment], to turns: [SpeakerTurn], speakerIDs: [String: UUID]
    ) -> [TranscriptSegment] {
        zip(segments, labels(for: segments, turns: turns)).map { segment, label in
            var aligned = segment
            aligned.speakerID = label.flatMap { speakerIDs[$0] }
            return aligned
        }
    }

    // MARK: Private

    /// Sorts, drops empty turns, and absorbs short flips between two spans of
    /// one voice. Runs until the timeline is stable, because absorbing one flip
    /// can leave the merged span sandwiching the next.
    static func smoothing(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        var result = turns.filter { $0.duration > 0 }.sorted { $0.startTime < $1.startTime }
        var index = 1
        while index + 1 < result.count {
            let flip = result[index]
            let before = result[index - 1]
            let after = result[index + 1]
            guard flip.duration < minimumTurnDuration,
                before.diarizerLabel == after.diarizerLabel,
                before.diarizerLabel != flip.diarizerLabel
            else {
                index += 1
                continue
            }
            result[index - 1].endTime = max(before.endTime, after.endTime)
            result.removeSubrange(index...(index + 1))
        }
        return result
    }

    /// The label holding the most of this segment's duration.
    ///
    /// Overlap is accumulated per label rather than per turn, so a voice split
    /// across two turns still beats one long turn from someone else, and
    /// simultaneous speech resolves to whoever holds more of the segment. Ties
    /// break on the label so the same input always produces the same output.
    private static func dominantLabel(
        for segment: TranscriptSegment, in turns: [SpeakerTurn]
    ) -> String? {
        var overlaps: [String: TimeInterval] = [:]
        for turn in turns {
            let overlap =
                min(segment.endTime, turn.endTime) - max(segment.startTime, turn.startTime)
            if overlap > 0 { overlaps[turn.diarizerLabel, default: 0] += overlap }
        }
        return overlaps.max { left, right in
            left.value == right.value ? left.key > right.key : left.value < right.value
        }?.key
    }
}
