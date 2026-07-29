import Foundation

/// Which pipeline stage produced a segment.
///
/// Live segments are provisional and are replaced wholesale by the final pass;
/// `userEdited` segments are never overwritten automatically (plan §6.5 step 6).
public enum SegmentSource: String, Codable, Sendable {
    case live
    case final
    case userEdited
}

/// One timestamped span of transcript text attributed to at most one speaker.
public struct TranscriptSegment: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var recordingID: UUID
    public var speakerID: UUID?
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String
    public var confidence: Double?
    public var isFinal: Bool
    public var source: SegmentSource

    public init(
        id: UUID = UUID(),
        recordingID: UUID,
        speakerID: UUID? = nil,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        confidence: Double? = nil,
        isFinal: Bool = false,
        source: SegmentSource = .live
    ) {
        self.id = id
        self.recordingID = recordingID
        self.speakerID = speakerID
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.confidence = confidence
        self.isFinal = isFinal
        self.source = source
    }

    public var duration: TimeInterval { max(0, endTime - startTime) }
}

/// A word with its own timing, used to align diarization turns against text
/// more precisely than segment boundaries allow (plan §6.5 step 5).
public struct TranscriptWord: Codable, Sendable, Equatable {
    public var text: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var confidence: Double?

    public init(
        text: String, startTime: TimeInterval, endTime: TimeInterval, confidence: Double? = nil
    ) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}
