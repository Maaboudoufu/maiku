import SwiftUI

/// Subtle scan lines and a soft vignette (plan §13.1). Static — no pulsing,
/// no animation — so it reads as a warm CRT glow rather than a distracting
/// effect; still gated by `EffectsGating.showsCRTEffect` at the call site so
/// Reduce Motion and the effects toggle both turn it off outright.
///
/// Purely decorative: `.allowsHitTesting(false)` so it never intercepts a
/// click meant for the content underneath, and it carries no accessibility
/// element of its own.
public struct CRTOverlay: View {
    @Environment(\.theme) private var theme

    public init() {}

    public var body: some View {
        Canvas { context, size in
            // A faint dot grid first, so empty screens read as a lit
            // terminal surface rather than a flat void — then scan lines
            // on top, both at the same static, non-pulsing intensity.
            var gy: CGFloat = 0
            while gy < size.height {
                var gx: CGFloat = 0
                while gx < size.width {
                    context.fill(
                        Path(CGRect(x: gx, y: gy, width: 1, height: 1)),
                        with: .color(.white.opacity(0.05)))
                    gx += 16
                }
                gy += 16
            }
            var y: CGFloat = 0
            while y < size.height {
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                    with: .color(.black.opacity(0.1)))
                y += 3
            }
        }
        .overlay {
            RadialGradient(
                colors: [.clear, theme.color.border.opacity(0.28)],
                center: .center, startRadius: 0, endRadius: 900)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
