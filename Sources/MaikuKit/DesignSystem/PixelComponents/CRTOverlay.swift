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
            var y: CGFloat = 0
            while y < size.height {
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                    with: .color(.black.opacity(0.05)))
                y += 3
            }
        }
        .overlay {
            RadialGradient(
                colors: [.clear, theme.color.border.opacity(0.16)],
                center: .center, startRadius: 0, endRadius: 900)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
