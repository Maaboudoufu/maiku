import AppKit

/// The moments plan §13.2's "sound effects toggle" actually gates. Named by
/// meaning, not by which system sound plays, so the mapping below can change
/// without touching a call site.
///
/// Not `Sendable`: every cue is triggered from SwiftUI view code already on
/// the main actor, and none of this ever needs to cross an actor boundary.
public enum SoundCue: Equatable {
    case recordingStarted
    case recordingStopped
    case processingComplete
    case error
}

/// Behind a protocol so tests can assert a cue fired without a real system
/// sound (and without the flakiness of asserting on actual audio output) —
/// the same seam shape as `AudioCapturing`/`SpeechTranscribing`.
public protocol SoundPlaying {
    func play(_ cue: SoundCue)
}

/// Plain macOS system sounds (`NSSound(named:)`) rather than bundled audio
/// assets — every name below ships with macOS, so there is nothing to author,
/// license, or bundle for a handful of short UI chimes.
public struct SystemSoundPlayer: SoundPlaying {
    public init() {}

    public func play(_ cue: SoundCue) {
        NSSound(named: Self.name(for: cue))?.play()
    }

    private static func name(for cue: SoundCue) -> NSSound.Name {
        switch cue {
        case .recordingStarted: "Pop"
        case .recordingStopped: "Bottle"
        case .processingComplete: "Glass"
        case .error: "Basso"
        }
    }
}

/// Checks `AppSettings.soundEffectsEnabled` once, at the call site, rather
/// than inside `SystemSoundPlayer` — the player has no way to know about
/// settings, and a silent no-op call is easier to reason about than a second
/// hidden gate duplicating `EffectsGating`.
public struct GatedSoundPlayer: SoundPlaying {
    private let player: any SoundPlaying
    private let isEnabled: () -> Bool

    public init(player: any SoundPlaying = SystemSoundPlayer(), isEnabled: @escaping () -> Bool) {
        self.player = player
        self.isEnabled = isEnabled
    }

    public func play(_ cue: SoundCue) {
        guard isEnabled() else { return }
        player.play(cue)
    }
}
