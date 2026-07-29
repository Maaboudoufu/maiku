import Foundation
import Testing

@testable import MaikuKit

@Suite("Output validator")
struct OutputValidatorTests {

    private let recordingID = UUID()
    private let realSegmentID = UUID()
    private let otherRealSegmentID = UUID()
    private let hallucinatedSegmentID = UUID()
    private let realSpeakerID = UUID()
    private let hallucinatedSpeakerID = UUID()

    private var segments: [TranscriptSegment] {
        [
            TranscriptSegment(
                id: realSegmentID, recordingID: recordingID, speakerID: realSpeakerID, startTime: 0,
                endTime: 4, text: "We agreed to ship the importer on Friday.", isFinal: true, source: .final),
            TranscriptSegment(
                id: otherRealSegmentID, recordingID: recordingID, startTime: 4, endTime: 8,
                text: "Alex will write the migration notes.", isFinal: true, source: .final),
        ]
    }

    private var speakers: [Speaker] {
        [Speaker(id: realSpeakerID, recordingID: recordingID, diarizerLabel: "1")]
    }

    @Test("A claim citing a real segment id survives untouched")
    func validClaimSurvives() {
        let organized = OrganizedRecording(
            keyTakeaways: [
                SourcedStatement(text: "Ships Friday.", sourceSegmentIDs: [realSegmentID], confidence: 0.9)
            ])
        let result = OutputValidator.validate(organized, segments: segments, speakers: speakers)
        #expect(result.keyTakeaways.map(\.text) == ["Ships Friday."])
    }

    @Test("A claim citing only a hallucinated segment id is discarded")
    func hallucinatedOnlyClaimIsDiscarded() {
        let organized = OrganizedRecording(
            keyTakeaways: [
                SourcedStatement(text: "Invented.", sourceSegmentIDs: [hallucinatedSegmentID], confidence: 0.9)
            ])
        let result = OutputValidator.validate(organized, segments: segments, speakers: speakers)
        #expect(result.keyTakeaways.isEmpty)
    }

    @Test("A claim citing a mix of real and hallucinated ids keeps only the real ones")
    func mixedIDsAreFilteredNotDiscarded() {
        let organized = OrganizedRecording(
            decisions: [
                Decision(
                    text: "Ship Friday.",
                    sourceSegmentIDs: [realSegmentID, hallucinatedSegmentID, otherRealSegmentID],
                    confidence: 0.9)
            ])
        let result = OutputValidator.validate(organized, segments: segments, speakers: speakers)
        #expect(result.decisions.count == 1)
        #expect(Set(result.decisions[0].sourceSegmentIDs) == [realSegmentID, otherRealSegmentID])
    }

    @Test("A claim with no source ids at all is discarded")
    func emptySourceIsDiscarded() {
        let organized = OrganizedRecording(
            openQuestions: [SourcedStatement(text: "What about the docs?", sourceSegmentIDs: [], confidence: 0.5)])
        let result = OutputValidator.validate(organized, segments: segments, speakers: speakers)
        #expect(result.openQuestions.isEmpty)
    }

    @Test("Validation is applied to every sourced category, not just one")
    func everyCategoryIsValidated() {
        let organized = OrganizedRecording(
            organizedSections: [
                OrganizedSection(heading: "Scope", body: "x", sourceSegmentIDs: [hallucinatedSegmentID])
            ],
            keyTakeaways: [SourcedStatement(text: "x", sourceSegmentIDs: [hallucinatedSegmentID], confidence: 0.5)],
            decisions: [Decision(text: "x", sourceSegmentIDs: [hallucinatedSegmentID], confidence: 0.5)],
            actionItems: [ActionItem(task: "x", sourceSegmentIDs: [hallucinatedSegmentID], confidence: 0.5)],
            openQuestions: [SourcedStatement(text: "x", sourceSegmentIDs: [hallucinatedSegmentID], confidence: 0.5)],
            followUps: [SourcedStatement(text: "x", sourceSegmentIDs: [hallucinatedSegmentID], confidence: 0.5)],
            topics: [Topic(name: "x", sourceSegmentIDs: [hallucinatedSegmentID])])
        let result = OutputValidator.validate(organized, segments: segments, speakers: speakers)
        #expect(result.organizedSections.isEmpty)
        #expect(result.keyTakeaways.isEmpty)
        #expect(result.decisions.isEmpty)
        #expect(result.actionItems.isEmpty)
        #expect(result.openQuestions.isEmpty)
        #expect(result.followUps.isEmpty)
        #expect(result.topics.isEmpty)
    }

    @Test("An action item's owner speaker id is nulled when it does not match a real speaker")
    func hallucinatedOwnerSpeakerIsNulled() {
        let organized = OrganizedRecording(
            actionItems: [
                ActionItem(
                    task: "Write the notes.", ownerSpeakerID: hallucinatedSpeakerID, ownerText: "Alex",
                    sourceSegmentIDs: [otherRealSegmentID], confidence: 0.8)
            ])
        let result = OutputValidator.validate(organized, segments: segments, speakers: speakers)
        #expect(result.actionItems.count == 1)
        #expect(result.actionItems[0].ownerSpeakerID == nil)
        #expect(result.actionItems[0].ownerText == "Alex", "ownerText is untouched even when ownerSpeakerID is cleared")
    }

    @Test("An action item's real owner speaker id is preserved")
    func realOwnerSpeakerIsPreserved() {
        let organized = OrganizedRecording(
            actionItems: [
                ActionItem(
                    task: "Ship it.", ownerSpeakerID: realSpeakerID, sourceSegmentIDs: [realSegmentID],
                    confidence: 0.8)
            ])
        let result = OutputValidator.validate(organized, segments: segments, speakers: speakers)
        #expect(result.actionItems[0].ownerSpeakerID == realSpeakerID)
    }

    @Test("A quote matching its cited segment, word for word, survives")
    func exactQuoteSurvives() {
        let organized = OrganizedRecording(
            quotes: [
                ImportantQuote(
                    exactText: "We agreed to ship the importer on Friday.", segmentID: realSegmentID,
                    startTime: 0, endTime: 4)
            ])
        let result = OutputValidator.validate(organized, segments: segments, speakers: speakers)
        #expect(result.quotes.count == 1)
    }

    @Test("A quote that is a genuine partial excerpt of its segment survives")
    func partialQuoteSurvives() {
        let organized = OrganizedRecording(
            quotes: [
                ImportantQuote(exactText: "ship the importer", segmentID: realSegmentID, startTime: 0, endTime: 4)
            ])
        let result = OutputValidator.validate(organized, segments: segments, speakers: speakers)
        #expect(result.quotes.count == 1)
    }

    @Test("Whitespace differences (extra spaces, newlines) do not break a quote match")
    func whitespaceNormalisationTolerated() {
        let organized = OrganizedRecording(
            quotes: [
                ImportantQuote(
                    exactText: "We  agreed\nto ship   the importer on Friday.", segmentID: realSegmentID,
                    startTime: 0, endTime: 4)
            ])
        let result = OutputValidator.validate(organized, segments: segments, speakers: speakers)
        #expect(result.quotes.count == 1)
    }

    @Test("A quote citing a segment id that does not exist is discarded")
    func quoteWithHallucinatedSegmentIsDiscarded() {
        let organized = OrganizedRecording(
            quotes: [
                ImportantQuote(exactText: "anything", segmentID: hallucinatedSegmentID, startTime: 0, endTime: 4)
            ])
        let result = OutputValidator.validate(organized, segments: segments, speakers: speakers)
        #expect(result.quotes.isEmpty)
    }

    @Test("A quote whose text does not actually appear in its cited segment is discarded")
    func quoteWithMismatchedTextIsDiscarded() {
        let organized = OrganizedRecording(
            quotes: [
                ImportantQuote(
                    exactText: "We agreed to cancel the launch entirely.", segmentID: realSegmentID, startTime: 0,
                    endTime: 4)
            ])
        let result = OutputValidator.validate(organized, segments: segments, speakers: speakers)
        #expect(result.quotes.isEmpty)
    }

    @Test("An empty quote string is discarded rather than matching everything")
    func emptyQuoteIsDiscarded() {
        let organized = OrganizedRecording(
            quotes: [ImportantQuote(exactText: "   ", segmentID: realSegmentID, startTime: 0, endTime: 4)])
        let result = OutputValidator.validate(organized, segments: segments, speakers: speakers)
        #expect(result.quotes.isEmpty)
    }

    @Test("A quote's speaker id is nulled when it does not match a real speaker, but the quote survives")
    func quoteHallucinatedSpeakerIsNulledNotDiscarded() {
        let organized = OrganizedRecording(
            quotes: [
                ImportantQuote(
                    exactText: "We agreed to ship the importer on Friday.", speakerID: hallucinatedSpeakerID,
                    segmentID: realSegmentID, startTime: 0, endTime: 4)
            ])
        let result = OutputValidator.validate(organized, segments: segments, speakers: speakers)
        #expect(result.quotes.count == 1)
        #expect(result.quotes[0].speakerID == nil)
    }

    @Test("A speaker summary's hallucinated speaker id is nulled, and the entry is not discarded")
    func speakerSummaryHallucinatedIDIsNulled() {
        let organized = OrganizedRecording(
            speakerSummary: [
                SpeakerSummary(speakerID: hallucinatedSpeakerID, displayName: "Speaker 2", contribution: "Took notes.")
            ])
        let result = OutputValidator.validate(organized, segments: segments, speakers: speakers)
        #expect(result.speakerSummary.count == 1)
        #expect(result.speakerSummary[0].speakerID == nil)
        #expect(result.speakerSummary[0].displayName == "Speaker 2")
    }

    @Test("With no segments and no speakers at all, every sourced claim is discarded and every reference nulled")
    func emptyRecordingDiscardsEverything() {
        let organized = OrganizedRecording(
            keyTakeaways: [SourcedStatement(text: "x", sourceSegmentIDs: [realSegmentID], confidence: 0.5)],
            quotes: [ImportantQuote(exactText: "x", segmentID: realSegmentID, startTime: 0, endTime: 1)])
        let result = OutputValidator.validate(organized, segments: [], speakers: [])
        #expect(result.keyTakeaways.isEmpty)
        #expect(result.quotes.isEmpty)
    }
}
