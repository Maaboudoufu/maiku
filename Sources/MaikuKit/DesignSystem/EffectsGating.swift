import Foundation
import SwiftUI

/// Plan §13.2: "Respect Reduce Motion" and "Let users disable sound effects
/// and CRT effects." Pulled out as pure functions rather than inlined at each
/// call site so the three settings/system-state combinations are each
/// checked once, directly, instead of only inferred from reading the views
/// that use them.
public enum EffectsGating {
    /// The system's own Reduce Motion wins when the user hasn't overridden
    /// it; `AppSettings.reducedMotionOverride` wins when they have.
    public static func effectiveReduceMotion(override: Bool?, systemReduceMotion: Bool) -> Bool {
        override ?? systemReduceMotion
    }

    /// CRT scan lines and glow: off if the user disabled the effect, and off
    /// under Reduce Motion regardless of that toggle — a glow that pulses
    /// (plan §13.1's "and glow") is exactly the kind of motion Reduce Motion
    /// is asking to suppress.
    public static func showsCRTEffect(crtEffectsEnabled: Bool, reduceMotion: Bool) -> Bool {
        crtEffectsEnabled && !reduceMotion
    }
}

// MARK: - Environment

/// `EnvironmentValues.accessibilityReduceMotion` is get-only — SwiftUI does
/// not let a view override the system's own reduce-motion signal. This is a
/// second, writable key: `RootView` sets it once, near the root, to
/// `EffectsGating.effectiveReduceMotion(...)`; `ClawdView`/`PixelProgress`
/// read this instead of the system key directly, so the per-user override
/// actually reaches them.
private struct EffectiveReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    public var effectiveReduceMotion: Bool {
        get { self[EffectiveReduceMotionKey.self] }
        set { self[EffectiveReduceMotionKey.self] = newValue }
    }
}
