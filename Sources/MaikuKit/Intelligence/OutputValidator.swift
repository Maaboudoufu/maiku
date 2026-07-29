import Foundation

/// Applies plan §7.4's hallucination controls to a model's structured
/// output, as a second, independent check after decoding — the schema and
/// the prompt rules ask the model to behave, this is what happens when it
/// doesn't. Every claim must cite at least one segment id that actually
/// exists in this recording's transcript; a claim left with none, after
/// filtering, is discarded rather than kept as an unsourced assertion.
/// Every quote must match the segment it claims to be from, after
/// whitespace normalisation, or it is discarded too. An owner or speaker
/// reference that does not match a real speaker is nulled rather than
/// dropping the whole item — the item's truthfulness rests on its sources,
/// not on knowing who said it.
public enum OutputValidator {

    public static func validate(
        _ organized: OrganizedRecording, segments: [TranscriptSegment], speakers: [Speaker]
    ) -> OrganizedRecording {
        let validSegmentIDs = Set(segments.map(\.id))
        let segmentsByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        let validSpeakerIDs = Set(speakers.map(\.id))

        var result = organized

        result.organizedSections = validateSourced(
            organized.organizedSections, validIDs: validSegmentIDs,
            sourceIDs: { $0.sourceSegmentIDs }, setSourceIDs: { $0.sourceSegmentIDs = $1 })
        result.keyTakeaways = validateSourced(
            organized.keyTakeaways, validIDs: validSegmentIDs,
            sourceIDs: { $0.sourceSegmentIDs }, setSourceIDs: { $0.sourceSegmentIDs = $1 })
        result.decisions = validateSourced(
            organized.decisions, validIDs: validSegmentIDs,
            sourceIDs: { $0.sourceSegmentIDs }, setSourceIDs: { $0.sourceSegmentIDs = $1 })
        result.openQuestions = validateSourced(
            organized.openQuestions, validIDs: validSegmentIDs,
            sourceIDs: { $0.sourceSegmentIDs }, setSourceIDs: { $0.sourceSegmentIDs = $1 })
        result.followUps = validateSourced(
            organized.followUps, validIDs: validSegmentIDs,
            sourceIDs: { $0.sourceSegmentIDs }, setSourceIDs: { $0.sourceSegmentIDs = $1 })
        result.topics = validateSourced(
            organized.topics, validIDs: validSegmentIDs,
            sourceIDs: { $0.sourceSegmentIDs }, setSourceIDs: { $0.sourceSegmentIDs = $1 })

        result.actionItems = validateSourced(
            organized.actionItems, validIDs: validSegmentIDs,
            sourceIDs: { $0.sourceSegmentIDs }, setSourceIDs: { $0.sourceSegmentIDs = $1}
        ).map { item in
            var item = item
            if let owner = item.ownerSpeakerID, !validSpeakerIDs.contains(owner) {
                item.ownerSpeakerID = nil
            }
            return item
        }

        result.quotes = organized.quotes.compactMap { quote -> ImportantQuote? in
            guard let segment = segmentsByID[quote.segmentID], quoteMatches(quote.exactText, in: segment.text)
            else { return nil }
            var quote = quote
            if let speakerID = quote.speakerID, !validSpeakerIDs.contains(speakerID) {
                quote.speakerID = nil
            }
            return quote
        }

        result.speakerSummary = organized.speakerSummary.map { summary in
            var summary = summary
            if let speakerID = summary.speakerID, !validSpeakerIDs.contains(speakerID) {
                summary.speakerID = nil
            }
            return summary
        }

        return result
    }

    /// Filters `sourceSegmentIDs` to ids that actually exist in this
    /// recording, then drops the item entirely if nothing valid is left —
    /// plan §7.4's "if nothing supports a claim, leave the claim out"
    /// applied uniformly across every sourced type, without a shared
    /// protocol these otherwise-unrelated structs would all need to adopt.
    private static func validateSourced<T>(
        _ items: [T], validIDs: Set<UUID>, sourceIDs: (T) -> [UUID], setSourceIDs: (inout T, [UUID]) -> Void
    ) -> [T] {
        items.compactMap { item in
            let filtered = sourceIDs(item).filter { validIDs.contains($0) }
            guard !filtered.isEmpty else { return nil }
            var item = item
            setSourceIDs(&item, filtered)
            return item
        }
    }

    /// Whitespace-normalised substring match: the model may quote only part
    /// of a longer segment, so equality would reject legitimate quotes: a
    /// quote's normalised text must appear somewhere in its segment's
    /// normalised text.
    private static func quoteMatches(_ quoteText: String, in segmentText: String) -> Bool {
        let normalizedQuote = normalize(quoteText)
        guard !normalizedQuote.isEmpty else { return false }
        return normalize(segmentText).contains(normalizedQuote)
    }

    private static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
