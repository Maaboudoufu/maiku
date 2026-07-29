import Foundation

/// What the mascot is doing. Exactly the states plan §14 requires — one per
/// product state the user can be in, so a screen never has to invent a mood.
public enum ClawdState: Equatable, Sendable {
    case idle
    case ready
    case listening(level: Float)
    case paused
    case transcribing
    case organizing(progress: Double?)
    case complete
    case error
    case lmStudioDisconnected
}

extension ClawdState {

    /// Short text shown beside the sprite.
    ///
    /// The mascot must not carry state by colour or picture alone (plan §13.2),
    /// so every state has words attached to it by default.
    public var caption: String {
        switch self {
        case .idle: "Idle"
        case .ready: "Ready"
        case .listening: "Listening"
        case .paused: "Paused"
        case .transcribing: "Transcribing"
        case .organizing: "Organizing"
        case .complete: "Done"
        case .error: "Problem"
        case .lmStudioDisconnected: "LM Studio offline"
        }
    }

    /// VoiceOver label. Fixed per state, because the level and progress change
    /// several times a second and re-announcing a whole sentence is unusable —
    /// those go in `accessibilityValue`.
    public var accessibilityLabel: String {
        switch self {
        case .idle: "Clawd is idle, holding a notebook"
        case .ready: "Clawd is ready to record, beside a microphone"
        case .listening: "Clawd is listening, holding the microphone"
        case .paused: "Clawd is resting. Recording is paused."
        case .transcribing: "Clawd is transcribing at a terminal"
        case .organizing: "Clawd is sorting notes into folders"
        case .complete: "Clawd is holding a finished page. Notes are ready."
        case .error: "Clawd is holding a tangled microphone cable. Something went wrong."
        case .lmStudioDisconnected:
            "Clawd is beside an unplugged computer. LM Studio is not connected."
        }
    }

    /// The part that changes while the state does not.
    public var accessibilityValue: String? {
        switch self {
        case .listening(let level):
            "Input level \(percent(Double(level))) percent"
        case .organizing(let progress):
            progress.map { "\(percent($0)) percent" }
        default:
            nil
        }
    }

    /// Clamped because levels come from the audio thread and progress from a
    /// model callback; neither is guaranteed to be 0…1 or even finite.
    private func percent(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int((min(max(value, 0), 1) * 100).rounded())
    }
}
