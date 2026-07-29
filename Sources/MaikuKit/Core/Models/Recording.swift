import Foundation

/// Lifecycle of a recording as persisted in the `recordings` table.
///
/// This mirrors the processing pipeline in `plan.md` §6.1. It is stored as a
/// string so that adding a stage later does not renumber existing rows.
public enum RecordingStatus: String, Codable, Sendable, CaseIterable {
    case recording
    case finalizingAudio
    case finalTranscription
    case finalDiarization
    case organizingChunks
    case organizingFinal
    case complete
    case failed
    case trashed

    /// True while a background pipeline stage is expected to be running.
    public var isProcessing: Bool {
        switch self {
        case .finalizingAudio, .finalTranscription, .finalDiarization, .organizingChunks,
            .organizingFinal:
            true
        case .recording, .complete, .failed, .trashed:
            false
        }
    }
}

/// A single captured session plus everything derived from it.
///
/// Audio lives on disk; only the path relative to the app data directory is
/// stored, so moving or renaming the container does not orphan recordings.
public struct Recording: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var title: String
    public var status: RecordingStatus
    public var recordingStartedAt: Date
    public var recordingEndedAt: Date?
    public var durationSeconds: TimeInterval
    /// Path relative to the app data directory, e.g. `Audio/<uuid>/archive.m4a`.
    public var audioRelativePath: String?
    /// Lossless working file written during capture, e.g. `Audio/<uuid>/capture.caf`.
    public var workingAudioRelativePath: String?
    public var transcriptionModel: String?
    public var lmStudioModel: String?
    /// BCP-47 language tag. Version 1 ships English only but the field is
    /// preserved so detection can be added without a migration.
    public var language: String
    public var errorStage: String?
    public var errorMessage: String?
    /// 0…1, or nil when the current stage cannot report determinate progress.
    public var processingProgress: Double?
    public var trashedAt: Date?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        title: String = "",
        status: RecordingStatus = .recording,
        recordingStartedAt: Date = Date(),
        recordingEndedAt: Date? = nil,
        durationSeconds: TimeInterval = 0,
        audioRelativePath: String? = nil,
        workingAudioRelativePath: String? = nil,
        transcriptionModel: String? = nil,
        lmStudioModel: String? = nil,
        language: String = "en",
        errorStage: String? = nil,
        errorMessage: String? = nil,
        processingProgress: Double? = nil,
        trashedAt: Date? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title
        self.status = status
        self.recordingStartedAt = recordingStartedAt
        self.recordingEndedAt = recordingEndedAt
        self.durationSeconds = durationSeconds
        self.audioRelativePath = audioRelativePath
        self.workingAudioRelativePath = workingAudioRelativePath
        self.transcriptionModel = transcriptionModel
        self.lmStudioModel = lmStudioModel
        self.language = language
        self.errorStage = errorStage
        self.errorMessage = errorMessage
        self.processingProgress = processingProgress
        self.trashedAt = trashedAt
    }
}
