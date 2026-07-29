import Foundation
import Network

/// Everything needed to talk to one LM Studio server.
///
/// `baseURL` is normalised on the way in because users paste the URL they see
/// in LM Studio's server tab, which usually already ends in `/v1`.
public struct LMStudioConfiguration: Sendable, Equatable {
    public let baseURL: URL
    /// Persisted model id chosen by the user. When nil the first listed model wins.
    public var modelID: String?
    public var timeout: TimeInterval
    public var temperature: Double
    /// Bearer token for users who turned on LM Studio authentication. Lives in
    /// the Keychain, never in UserDefaults or SQLite (plan §12).
    public var apiToken: String?

    public static let defaultBaseURL = URL(string: "http://127.0.0.1:1234")!

    public init(
        baseURL: URL = LMStudioConfiguration.defaultBaseURL,
        modelID: String? = nil,
        timeout: TimeInterval = 120,
        temperature: Double = 0.2,
        apiToken: String? = nil
    ) {
        self.baseURL = Self.normalized(baseURL)
        self.modelID = modelID
        self.timeout = timeout
        self.temperature = temperature
        self.apiToken = apiToken
    }

    /// Loopback means transcript text never leaves the machine. The UI warns
    /// when this is false but does not block it (plan §12).
    public var isLoopback: Bool {
        let host = (baseURL.host ?? "").lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        // Strict parsers: a hostname like "127.evil.com" is not an address and
        // is correctly reported as non-loopback.
        // The whole 127.0.0.0/8 block is loopback (RFC 1122 §3.2.1.3), but
        // IPv4Address.isLoopback only matches 127.0.0.1 exactly, so testing it
        // alone would warn the user about traffic that never leaves the host.
        if let v4 = IPv4Address(host) { return v4.rawValue.first == 127 }
        if let v6 = IPv6Address(host) { return v6.isLoopback }
        return false
    }

    /// Turns whatever the user typed into a usable base URL, or nil.
    /// `127.0.0.1:1234` parses as a URL with scheme "127.0.0.1", so a missing
    /// scheme has to be filled in rather than trusted.
    public static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", url.host?.isEmpty == false
        else { return nil }
        return normalized(url)
    }

    private static func normalized(_ url: URL) -> URL {
        var text = url.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/v1") { text.removeLast(3) }
        return URL(string: text) ?? url
    }
}

public struct LMStudioModel: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let ownedBy: String?

    public init(id: String, ownedBy: String? = nil) {
        self.id = id
        self.ownedBy = ownedBy
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case ownedBy = "owned_by"
    }
}

/// Result of a successful reachability probe. Failure is an error, not a
/// status, so no call site can silently ignore "LM Studio is not running".
public struct LMStudioConnectionStatus: Sendable, Equatable {
    public let baseURL: URL
    public let isLoopback: Bool
    public let models: [LMStudioModel]
}

/// One whole recording to organize.
public struct OrganizationRequest: Sendable, Equatable {
    public var recordingID: UUID
    public var recordedAt: Date
    public var durationSeconds: TimeInterval
    public var segments: [TranscriptSegment]
    public var speakers: [Speaker]

    public init(
        recordingID: UUID,
        recordedAt: Date,
        durationSeconds: TimeInterval,
        segments: [TranscriptSegment],
        speakers: [Speaker]
    ) {
        self.recordingID = recordingID
        self.recordedAt = recordedAt
        self.durationSeconds = durationSeconds
        self.segments = segments
        self.speakers = speakers
    }
}

/// One chunk of a long recording, for the map half of map-reduce (plan §7.2).
public struct ChunkSummaryRequest: Sendable, Equatable {
    public var chunkIndex: Int
    public var chunkCount: Int
    public var segments: [TranscriptSegment]
    public var speakers: [Speaker]

    public init(
        chunkIndex: Int, chunkCount: Int, segments: [TranscriptSegment], speakers: [Speaker]
    ) {
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
        self.segments = segments
        self.speakers = speakers
    }
}

/// What one chunk supports on its own. Deliberately claim-shaped rather than
/// prose-shaped so the reduce pass can deduplicate and keep segment references.
public struct ChunkSummary: Codable, Sendable, Equatable {
    public var summary: String
    public var topics: [Topic]
    public var keyPoints: [SourcedStatement]
    public var decisions: [Decision]
    public var actionItems: [ActionItem]
    public var openQuestions: [SourcedStatement]
    public var quotes: [ImportantQuote]
    public var tags: [String]

    public init(
        summary: String = "",
        topics: [Topic] = [],
        keyPoints: [SourcedStatement] = [],
        decisions: [Decision] = [],
        actionItems: [ActionItem] = [],
        openQuestions: [SourcedStatement] = [],
        quotes: [ImportantQuote] = [],
        tags: [String] = []
    ) {
        self.summary = summary
        self.topics = topics
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.quotes = quotes
        self.tags = tags
    }
}

/// Pass 2's input when a recording needed more than one chunk (plan §7.2):
/// every chunk's extracted claims, not the raw transcript — the reduce pass
/// combines and deduplicates what pass 1 already found, it does not
/// re-extract from scratch.
public struct ReduceRequest: Sendable, Equatable {
    public var recordingID: UUID
    public var recordedAt: Date
    public var durationSeconds: TimeInterval
    public var chunkSummaries: [ChunkSummary]
    public var speakers: [Speaker]

    public init(
        recordingID: UUID, recordedAt: Date, durationSeconds: TimeInterval,
        chunkSummaries: [ChunkSummary], speakers: [Speaker]
    ) {
        self.recordingID = recordingID
        self.recordedAt = recordedAt
        self.durationSeconds = durationSeconds
        self.chunkSummaries = chunkSummaries
        self.speakers = speakers
    }
}

// MARK: - Wire types

struct ChatMessage: Sendable, Equatable {
    let role: String
    let content: String

    var wireForm: [String: Any] { ["role": role, "content": content] }
}

struct ModelListResponse: Decodable {
    let data: [LMStudioModel]
}

struct ChatCompletionResponse: Decodable {
    struct Message: Decodable {
        let content: String?
    }

    struct Choice: Decodable {
        let message: Message
        let finishReason: String?

        private enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Usage: Decodable {
        let totalTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case totalTokens = "total_tokens"
        }
    }

    let choices: [Choice]
    let usage: Usage?
}
