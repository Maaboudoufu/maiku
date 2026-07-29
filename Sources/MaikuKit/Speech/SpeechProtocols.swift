import AVFoundation
import Foundation

/// Which Whisper weights to load, and how hard to work.
public struct SpeechModelConfiguration: Sendable, Equatable {
    /// WhisperKit model identifier, e.g. `"tiny.en"`, `"base.en"`, `"large-v3_turbo"`.
    public var modelName: String
    /// BCP-47 tag, or nil to let the engine detect. Version 1 passes `"en"`.
    public var language: String?
    /// Streaming passes trade accuracy for latency; the final pass does not.
    public var isStreamingPass: Bool

    public init(modelName: String, language: String? = "en", isStreamingPass: Bool = false) {
        self.modelName = modelName
        self.language = language
        self.isStreamingPass = isStreamingPass
    }
}

/// An incremental transcription result.
///
/// `stable` text will not change; `unstable` text may be rewritten by a later
/// update and must be rendered as provisional (plan §6.3).
public struct TranscriptionUpdate: Sendable, Equatable {
    public var stableSegments: [TranscriptSegment]
    public var unstableText: String
    public var windowStart: TimeInterval

    public init(
        stableSegments: [TranscriptSegment] = [], unstableText: String = "",
        windowStart: TimeInterval = 0
    ) {
        self.stableSegments = stableSegments
        self.unstableText = unstableText
        self.windowStart = windowStart
    }
}

/// The canonical transcription for a whole recording.
public struct FinalTranscription: Sendable, Equatable {
    public var segments: [TranscriptSegment]
    public var words: [TranscriptWord]
    public var detectedLanguage: String?
    public var modelName: String

    public init(
        segments: [TranscriptSegment], words: [TranscriptWord] = [],
        detectedLanguage: String? = nil, modelName: String
    ) {
        self.segments = segments
        self.words = words
        self.detectedLanguage = detectedLanguage
        self.modelName = modelName
    }
}

/// One contiguous span attributed to one speaker.
public struct SpeakerTurn: Sendable, Equatable {
    public var diarizerLabel: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var quality: Double

    public init(
        diarizerLabel: String, startTime: TimeInterval, endTime: TimeInterval, quality: Double = 1
    ) {
        self.diarizerLabel = diarizerLabel
        self.startTime = startTime
        self.endTime = endTime
        self.quality = quality
    }

    public var duration: TimeInterval { max(0, endTime - startTime) }
}

public struct DiarizationUpdate: Sendable, Equatable {
    public var turns: [SpeakerTurn]
    public init(turns: [SpeakerTurn]) { self.turns = turns }
}

public struct DiarizationResult: Sendable, Equatable {
    public var turns: [SpeakerTurn]
    public init(turns: [SpeakerTurn]) { self.turns = turns }

    public var speakerLabels: [String] { Array(Set(turns.map(\.diarizerLabel))).sorted() }
}

public struct VoiceActivityResult: Sendable, Equatable {
    public var containsSpeech: Bool
    public var probability: Double
    public init(containsSpeech: Bool, probability: Double) {
        self.containsSpeech = containsSpeech
        self.probability = probability
    }
}

/// Speech-to-text, streaming and whole-file.
///
/// Views never see WhisperKit types; adapters live behind this protocol so the
/// engine can be swapped (e.g. a `whisper.cpp` fallback for Intel Macs).
public protocol SpeechTranscribing: Sendable {
    func prepare(model: SpeechModelConfiguration) async throws
    func startStreaming() async throws
    func accept(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) async throws
    func updates() -> AsyncThrowingStream<TranscriptionUpdate, Error>
    func finishStreaming() async throws -> FinalTranscription
    func transcribeFile(at url: URL) async throws -> FinalTranscription
}

/// "Who spoke when", streaming and whole-file.
public protocol SpeakerDiarizing: Sendable {
    func prepare() async throws
    func startStreaming() async throws
    func accept(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) async throws
    func updates() -> AsyncThrowingStream<DiarizationUpdate, Error>
    func finishStreaming() async throws -> DiarizationResult
    func diarizeFile(at url: URL) async throws -> DiarizationResult
}

public protocol VoiceActivityDetecting: Sendable {
    func analyze(_ buffer: AVAudioPCMBuffer) async throws -> VoiceActivityResult
}
