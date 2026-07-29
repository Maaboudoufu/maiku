import Foundation

/// Everything the local model produced for one recording.
///
/// Every claim-bearing type carries `sourceSegmentIDs` so the interface can
/// jump to supporting audio and so `OutputValidator` can reject unsupported
/// output (plan §7.4).
public struct OrganizedRecording: Codable, Sendable, Equatable {
    public var title: String
    public var shortSummary: String
    public var detailedSummary: String
    public var organizedSections: [OrganizedSection]
    public var keyTakeaways: [SourcedStatement]
    public var decisions: [Decision]
    public var actionItems: [ActionItem]
    public var openQuestions: [SourcedStatement]
    public var followUps: [SourcedStatement]
    public var quotes: [ImportantQuote]
    public var topics: [Topic]
    public var tags: [String]
    public var speakerSummary: [SpeakerSummary]

    public init(
        title: String = "",
        shortSummary: String = "",
        detailedSummary: String = "",
        organizedSections: [OrganizedSection] = [],
        keyTakeaways: [SourcedStatement] = [],
        decisions: [Decision] = [],
        actionItems: [ActionItem] = [],
        openQuestions: [SourcedStatement] = [],
        followUps: [SourcedStatement] = [],
        quotes: [ImportantQuote] = [],
        topics: [Topic] = [],
        tags: [String] = [],
        speakerSummary: [SpeakerSummary] = []
    ) {
        self.title = title
        self.shortSummary = shortSummary
        self.detailedSummary = detailedSummary
        self.organizedSections = organizedSections
        self.keyTakeaways = keyTakeaways
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.followUps = followUps
        self.quotes = quotes
        self.topics = topics
        self.tags = tags
        self.speakerSummary = speakerSummary
    }
}

public struct SourcedStatement: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var text: String
    public var sourceSegmentIDs: [UUID]
    public var confidence: Double

    public init(
        id: UUID = UUID(), text: String, sourceSegmentIDs: [UUID] = [], confidence: Double = 1
    ) {
        self.id = id
        self.text = text
        self.sourceSegmentIDs = sourceSegmentIDs
        self.confidence = confidence
    }
}

public struct OrganizedSection: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var heading: String
    public var body: String
    public var sourceSegmentIDs: [UUID]

    public init(
        id: UUID = UUID(), heading: String, body: String, sourceSegmentIDs: [UUID] = []
    ) {
        self.id = id
        self.heading = heading
        self.body = body
        self.sourceSegmentIDs = sourceSegmentIDs
    }
}

public struct Decision: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var text: String
    public var rationale: String?
    public var sourceSegmentIDs: [UUID]
    public var confidence: Double

    public init(
        id: UUID = UUID(), text: String, rationale: String? = nil, sourceSegmentIDs: [UUID] = [],
        confidence: Double = 1
    ) {
        self.id = id
        self.text = text
        self.rationale = rationale
        self.sourceSegmentIDs = sourceSegmentIDs
        self.confidence = confidence
    }
}

public enum ActionItemStatus: String, Codable, Sendable, CaseIterable {
    case open
    case done
    case dismissed
}

public struct ActionItem: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var task: String
    /// Set only when the owner could be resolved to a diarized speaker.
    public var ownerSpeakerID: UUID?
    /// Owner exactly as spoken, when it could not be resolved to a speaker.
    /// Never a guess — nil when the transcript does not say (plan §7.4).
    public var ownerText: String?
    /// Absolute date only when the transcript supports resolving it; otherwise
    /// nil and the relative phrasing stays in `task`.
    public var dueDateISO8601: String?
    public var status: ActionItemStatus
    public var sourceSegmentIDs: [UUID]
    public var confidence: Double

    public init(
        id: UUID = UUID(),
        task: String,
        ownerSpeakerID: UUID? = nil,
        ownerText: String? = nil,
        dueDateISO8601: String? = nil,
        status: ActionItemStatus = .open,
        sourceSegmentIDs: [UUID] = [],
        confidence: Double = 1
    ) {
        self.id = id
        self.task = task
        self.ownerSpeakerID = ownerSpeakerID
        self.ownerText = ownerText
        self.dueDateISO8601 = dueDateISO8601
        self.status = status
        self.sourceSegmentIDs = sourceSegmentIDs
        self.confidence = confidence
    }
}

public struct ImportantQuote: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    /// Must match the referenced segment text after whitespace normalisation,
    /// or `OutputValidator` discards it.
    public var exactText: String
    public var speakerID: UUID?
    public var segmentID: UUID
    public var startTime: TimeInterval
    public var endTime: TimeInterval

    public init(
        id: UUID = UUID(),
        exactText: String,
        speakerID: UUID? = nil,
        segmentID: UUID,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) {
        self.id = id
        self.exactText = exactText
        self.speakerID = speakerID
        self.segmentID = segmentID
        self.startTime = startTime
        self.endTime = endTime
    }
}

public struct Topic: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var startTime: TimeInterval?
    public var endTime: TimeInterval?
    public var sourceSegmentIDs: [UUID]

    public init(
        id: UUID = UUID(), name: String, startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil, sourceSegmentIDs: [UUID] = []
    ) {
        self.id = id
        self.name = name
        self.startTime = startTime
        self.endTime = endTime
        self.sourceSegmentIDs = sourceSegmentIDs
    }
}

public struct SpeakerSummary: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var speakerID: UUID?
    public var displayName: String
    public var contribution: String
    public var speakingTimeSeconds: TimeInterval?

    public init(
        id: UUID = UUID(), speakerID: UUID? = nil, displayName: String, contribution: String,
        speakingTimeSeconds: TimeInterval? = nil
    ) {
        self.id = id
        self.speakerID = speakerID
        self.displayName = displayName
        self.contribution = contribution
        self.speakingTimeSeconds = speakingTimeSeconds
    }
}
