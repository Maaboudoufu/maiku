import Foundation

/// A recovery action a user can take, surfaced as a button next to the message.
///
/// Plan §19 requires every major error to offer something actionable; this type
/// exists so no call site can present a bare error code.
public enum RecoveryAction: Equatable, Sendable, Hashable {
    case openSystemSettingsMicrophone
    case retry
    case refreshDevices
    case downloadModel
    case chooseModel
    case selectSmallerModel
    case openSettings
    case continueWithoutNotes
    case retryWithSmallerChunks
    case retryOrganization
    case viewDiagnostics
    case chooseStorageLocation
    case deleteOldRecordings
    case stopSafely
    case recoverAndProcess
    case keepAudioOnly
    case delete

    public var title: String {
        switch self {
        case .openSystemSettingsMicrophone: "Open System Settings"
        case .retry: "Retry"
        case .refreshDevices: "Refresh Devices"
        case .downloadModel: "Download Model"
        case .chooseModel: "Choose Model"
        case .selectSmallerModel: "Select Smaller Model"
        case .openSettings: "Open Settings"
        case .continueWithoutNotes: "Continue Without Notes"
        case .retryWithSmallerChunks: "Retry With Smaller Chunks"
        case .retryOrganization: "Retry Organization"
        case .viewDiagnostics: "View Diagnostics"
        case .chooseStorageLocation: "Choose Storage Location"
        case .deleteOldRecordings: "Delete Old Recordings"
        case .stopSafely: "Stop Safely"
        case .recoverAndProcess: "Recover and Process"
        case .keepAudioOnly: "Keep Audio"
        case .delete: "Delete"
        }
    }
}

/// Every user-visible failure in Maiku.
///
/// Cases are distinguished finely enough that the interface can tell
/// "LM Studio is not running" apart from "no model is available" and
/// "the model returned invalid structured output" (plan §5.3).
public enum MaikuError: Error, Equatable, Sendable {
    // Audio
    case microphonePermissionDenied
    case microphonePermissionUndetermined
    case noMicrophoneFound
    case microphoneDisconnected
    case audioEngineFailed(String)
    case audioFileWriteFailed(String)
    case lowDiskSpace(availableBytes: Int64)

    // Speech
    case speechModelMissing(name: String)
    case speechModelLoadFailed(name: String, underlying: String)
    case transcriptionFailed(String)
    case diarizationFailed(String)

    // LM Studio
    case lmStudioUnreachable(baseURL: String)
    case lmStudioNoModelAvailable
    case lmStudioTimedOut(seconds: TimeInterval)
    case lmStudioContextTooLarge(tokens: Int?)
    case lmStudioInvalidStructuredOutput(detail: String)
    case lmStudioHTTPError(status: Int, body: String)

    // Persistence
    case databaseFailure(String)
    case recordingNotFound(UUID)
    case fileIntegrityCheckFailed(path: String)
    case keychainFailure(String)

    /// Short sentence describing what happened, in plain language.
    public var message: String {
        switch self {
        case .microphonePermissionDenied:
            "maiku does not have permission to use the microphone."
        case .microphonePermissionUndetermined:
            "maiku needs your permission to use the microphone."
        case .noMicrophoneFound:
            "No microphone is connected."
        case .microphoneDisconnected:
            "The microphone was disconnected. Audio captured so far has been kept."
        case .audioEngineFailed(let detail):
            "The audio engine could not start. \(detail)"
        case .audioFileWriteFailed(let detail):
            "maiku could not write the recording to disk. \(detail)"
        case .lowDiskSpace(let bytes):
            "Low disk space — \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) free."
        case .speechModelMissing(let name):
            "The speech model “\(name)” is not installed."
        case .speechModelLoadFailed(let name, let underlying):
            "The speech model “\(name)” failed to load. \(underlying)"
        case .transcriptionFailed(let detail):
            "Transcription failed. \(detail)"
        case .diarizationFailed(let detail):
            "Speaker identification failed. The transcript has been kept. \(detail)"
        case .lmStudioUnreachable(let url):
            "maiku could not reach LM Studio at \(url). Is it running?"
        case .lmStudioNoModelAvailable:
            "LM Studio is running but no model is loaded."
        case .lmStudioTimedOut(let seconds):
            "LM Studio did not respond within \(Int(seconds)) seconds."
        case .lmStudioContextTooLarge(let tokens):
            tokens.map { "The transcript chunk is too large for the model’s context (\($0) tokens)." }
                ?? "The transcript chunk is too large for the model’s context."
        case .lmStudioInvalidStructuredOutput(let detail):
            "The model returned notes that did not match the expected format. \(detail)"
        case .lmStudioHTTPError(let status, _):
            "LM Studio returned an unexpected response (HTTP \(status))."
        case .databaseFailure(let detail):
            "maiku could not read or write its database. \(detail)"
        case .recordingNotFound:
            "That recording no longer exists."
        case .fileIntegrityCheckFailed(let path):
            "The audio file at \(path) appears to be incomplete."
        case .keychainFailure(let detail):
            "maiku could not read or write the LM Studio token in the Keychain. \(detail)"
        }
    }

    /// Actions offered alongside `message`. Order is the display order.
    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .microphonePermissionDenied, .microphonePermissionUndetermined:
            [.openSystemSettingsMicrophone, .retry]
        case .noMicrophoneFound, .microphoneDisconnected:
            [.refreshDevices, .retry]
        case .audioEngineFailed:
            [.retry, .refreshDevices]
        case .audioFileWriteFailed:
            [.retry, .chooseStorageLocation]
        case .lowDiskSpace:
            [.chooseStorageLocation, .deleteOldRecordings, .stopSafely]
        case .speechModelMissing:
            [.downloadModel, .chooseModel]
        case .speechModelLoadFailed:
            [.retry, .selectSmallerModel]
        case .transcriptionFailed, .diarizationFailed:
            [.retry, .viewDiagnostics]
        case .lmStudioUnreachable:
            [.retry, .openSettings, .continueWithoutNotes]
        case .lmStudioNoModelAvailable:
            [.chooseModel, .continueWithoutNotes]
        case .lmStudioTimedOut:
            [.retryOrganization, .openSettings, .continueWithoutNotes]
        case .lmStudioContextTooLarge:
            [.retryWithSmallerChunks, .openSettings]
        case .lmStudioInvalidStructuredOutput, .lmStudioHTTPError:
            [.retryOrganization, .viewDiagnostics]
        case .databaseFailure, .fileIntegrityCheckFailed, .keychainFailure:
            [.retry, .viewDiagnostics]
        case .recordingNotFound:
            []
        }
    }
}

extension MaikuError: LocalizedError {
    public var errorDescription: String? { message }
}
