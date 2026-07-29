import Foundation

/// The named stages a recording moves through, in order.
///
/// Kept separate from `RecordingState` so the processing screen can show a
/// stage list (plan §10.5) without pattern-matching associated values.
public enum ProcessingStage: String, Codable, Sendable, CaseIterable {
    case finalizingAudio
    case finalTranscription
    case finalDiarization
    case organizingChunks
    case organizingFinal

    /// Wording shown on the processing screen.
    public var displayName: String {
        switch self {
        case .finalizingAudio: "Saving audio"
        case .finalTranscription: "Finalizing transcript"
        case .finalDiarization: "Identifying speakers"
        case .organizingChunks: "Organizing notes"
        case .organizingFinal: "Saving results"
        }
    }
}

/// The explicit, persisted recording state machine from plan §6.1.
///
/// Illegal transitions are rejected by `canTransition(to:)` rather than being
/// merely discouraged, so a coordinator bug surfaces as a test failure instead
/// of a half-written recording.
public enum RecordingState: Equatable, Sendable {
    case idle
    case requestingPermission
    case preparingModels
    case ready
    case recording
    case paused
    case stopping
    case processing(ProcessingStage)
    case complete
    case failed(stage: String, message: String)

    /// Whether the microphone is live. Drives the always-visible recording
    /// indicator required by plan §12.
    public var isCapturingAudio: Bool {
        switch self {
        case .recording, .paused, .stopping: true
        default: false
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .complete, .failed: true
        default: false
        }
    }
}

extension RecordingState {
    /// Ordered processing stages, used to advance and to render progress.
    static let stageOrder: [ProcessingStage] = ProcessingStage.allCases

    /// Legal transitions. Any processing state may fail; a failure preserves
    /// everything completed before it, so `.failed` is never terminal-with-loss.
    public func canTransition(to next: RecordingState) -> Bool {
        // Recovering from a failure re-enters the pipeline at any stage, and
        // any stage may fail.
        if case .failed = next { return !isTerminal || isFailed }
        if case .failed = self {
            switch next {
            case .idle, .ready, .processing, .complete: return true
            default: return false
            }
        }

        switch (self, next) {
        case (.idle, .requestingPermission),
            (.idle, .ready):
            return true
        case (.requestingPermission, .preparingModels),
            (.requestingPermission, .idle):
            return true
        case (.preparingModels, .ready),
            (.preparingModels, .idle):
            return true
        case (.ready, .recording),
            (.ready, .idle):
            return true
        case (.recording, .paused),
            (.recording, .stopping):
            return true
        case (.paused, .recording),
            (.paused, .stopping):
            return true
        case (.stopping, .processing(.finalizingAudio)):
            return true
        case (.processing(let a), .processing(let b)):
            // Forward one stage at a time, or re-run the current stage on retry.
            guard let i = Self.stageOrder.firstIndex(of: a),
                let j = Self.stageOrder.firstIndex(of: b)
            else { return false }
            return j == i + 1 || j == i
        case (.processing(.organizingFinal), .complete):
            return true
        case (.complete, .processing(.organizingChunks)):
            // "Retry organization" without retranscribing (plan §5.3).
            return true
        case (.complete, .idle),
            (.complete, .ready):
            return true
        default:
            return false
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
