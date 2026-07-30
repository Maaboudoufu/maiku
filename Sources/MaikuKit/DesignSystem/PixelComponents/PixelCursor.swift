import SwiftUI

/// A blinking terminal block cursor — the app's one recurring signature
/// mark, set beside the wordmark and other "live" chrome to read as a
/// terminal prompt rather than a static logo.
///
/// Static (always lit) under Reduce Motion, the same effects-gating rule
/// `PixelProgress`'s indeterminate state already follows — a flashing block
/// is exactly the kind of motion that setting asks to suppress.
public struct PixelCursor: View {
    @Environment(\.theme) private var theme
    @Environment(\.effectiveReduceMotion) private var reduceMotion

    private let width: CGFloat
    private let height: CGFloat
    private let interval: TimeInterval = 0.53

    public init(width: CGFloat = 9, height: CGFloat = 20) {
        self.width = width
        self.height = height
    }

    public var body: some View {
        Group {
            if reduceMotion {
                theme.color.accent
            } else {
                TimelineView(.periodic(from: .now, by: interval)) { context in
                    let tick = Int(context.date.timeIntervalSinceReferenceDate / interval)
                    theme.color.accent.opacity(tick.isMultiple(of: 2) ? 1 : 0)
                }
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}
