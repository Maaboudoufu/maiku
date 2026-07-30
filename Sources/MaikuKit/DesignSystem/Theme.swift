import AppKit
import SwiftUI

/// Semantic design tokens for the 8-bit look (plan §13).
///
/// Every colour, metric and font used by the interface is named here so that
/// no view has to invent one. Views read the active theme with
/// `@Environment(\.theme)`; the environment always has a value, so a view is
/// never left guessing.
public struct Theme: Sendable {
    public var color = Colors()
    public var space = Spacing()
    public var corner = Corners()
    public var border = Borders()
    public var shadow = PixelShadow()
    public var font = Typography()
    public var duration = Durations()

    public init() {}
}

// MARK: - Colour

extension Theme {
    /// Warm cream in light appearance, very dark brown in dark appearance.
    ///
    /// Red is deliberately narrow: `recording` and `destructive` only. Nothing
    /// else in the interface may be red, so a red pixel always means "the
    /// microphone is live" or "this cannot be undone" (plan §13.1).
    public struct Colors: Sendable {
        // Surfaces
        public var surface = dyn(0xF4EB_DC, 0x1711_0C)
        public var surfaceRaised = dyn(0xFCF6_EA, 0x241A_12)
        public var surfaceSunken = dyn(0xE6D9_C3, 0x100B_07)

        // Lines
        public var border = dyn(0x3B2A_1E, 0x8A74_5A)
        public var borderSubtle = dyn(0xC9B7_9B, 0x3A2C_20)
        public var focusRing = dyn(0xE07A_17, 0xFF9A_3C)

        // Text
        public var textPrimary = dyn(0x2B1E_14, 0xF2E7_D5)
        public var textSecondary = dyn(0x6B58_44, 0xB7A4_89)

        // Emphasis
        public var accent = dyn(0xE07A_17, 0xFF9A_3C)
        public var accentPressed = dyn(0xB85F_0B, 0xD97A_1E)
        /// Text drawn on top of `accent`.
        public var onAccent = dyn(0x1F14_09, 0x1B11_09)
        /// Text drawn on top of `recording` / `destructive`.
        public var onDanger = dyn(0xFFF3_E6, 0x1B11_09)

        // Reserved
        public var recording = dyn(0xC42B_1C, 0xFF5A_48)
        public var destructive = dyn(0xC42B_1C, 0xFF5A_48)

        // Status that is not red. The light-theme values are darkened ~10%
        // from the first pass: at `.caption` size (well under WCAG's 18pt/14pt-bold
        // large-text exemption), the originals measured 4.22–4.28:1 against
        // `surface` — under the 4.5:1 AA threshold for normal text (plan §13.2).
        // Same hue, just enough darker to clear it with margin (~5:1).
        public var success = dyn(0x3870_34, 0x6FBF_63)
        public var warning = dyn(0x7C5F_09, 0xE8C2_5A)

        /// Per-speaker tints, indexed by `Speaker.colorIndex`. Deliberately
        /// avoids orange and red so a speaker badge can never be mistaken for
        /// the recording indicator.
        public var speakerRamp: [Color] = [
            dyn(0x2E8B_85, 0x52C7_BE),  // teal
            dyn(0x4A5F_C1, 0x8B9B_FF),  // indigo
            dyn(0x8C4A_9E, 0xC98B_E0),  // plum
            dyn(0x6E7F_2E, 0xA8C2_4F),  // olive
            dyn(0x8A5A_2B, 0xD19A_5C),  // tan
            dyn(0x4660_6E, 0x86AE_C2),  // slate
        ]

        public init() {}

        /// Speaker tint for any index, including negative or absurd ones —
        /// diarizers occasionally emit more labels than the ramp has entries.
        public func speaker(at index: Int) -> Color {
            let count = speakerRamp.count
            guard count > 0 else { return accent }
            // `%` never overflows here; `abs(Int.min)` would trap, so avoid it.
            let wrapped = index % count
            return speakerRamp[wrapped < 0 ? wrapped + count : wrapped]
        }
    }
}

/// Builds one appearance-aware colour. Resolving through `NSColor` means the
/// token follows the window's appearance without every view having to observe
/// `colorScheme`.
private func dyn(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> Color {
    Color(
        nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
        })
}

// MARK: - Metrics

extension Theme {
    /// A 4pt grid, which keeps every edge on a whole device pixel at 2x.
    public struct Spacing: Sendable {
        public var xxs: CGFloat = 2
        public var xs: CGFloat = 4
        public var sm: CGFloat = 8
        public var md: CGFloat = 12
        public var lg: CGFloat = 16
        public var xl: CGFloat = 24
        public var xxl: CGFloat = 32
        public init() {}
    }

    /// Notch sizes for `PixelCorner`, not radii — the corners are stepped.
    public struct Corners: Sendable {
        public var small: CGFloat = 2
        public var medium: CGFloat = 3
        public var large: CGFloat = 4
        public init() {}
    }

    /// Stroke widths in points. `hairline` is one point, which is the thinnest
    /// crisp line AppKit will draw on both 1x and 2x displays.
    public struct Borders: Sendable {
        public var hairline: CGFloat = 1
        public var thick: CGFloat = 2
        public init() {}
    }

    public struct Durations: Sendable {
        public var instant: Double = 0.08
        public var quick: Double = 0.14
        public var standard: Double = 0.24
        public var slow: Double = 0.4
        public init() {}
    }
}

/// A hard 8-bit drop shadow: an offset copy of the shape, never a blur.
public struct PixelShadow: Sendable, Equatable {
    public var offset = CGSize(width: 2, height: 2)
    public var color = dyn(0x3B2A_1E, 0x0000_00, alpha: 0.35)
    public init() {}
}

// MARK: - Type

extension Theme {
    /// Paragraphs use native text styles at native sizes; the monospaced faces
    /// are for chrome only (plan §13.1, §13.2). All of these are relative to
    /// a text style, so Dynamic Type still works.
    public struct Typography: Sendable {
        // Body copy — native, readable.
        public var body = Font.body
        public var bodyEmphasized = Font.body.weight(.semibold)
        public var secondary = Font.callout
        public var caption = Font.caption

        // Chrome — monospaced.
        //
        // ponytail: the system monospaced face stands in for the open-licensed
        // pixel font plan §13.1 allows. Swap in a real pixel font here (and
        // nowhere else) once one is vendored with its licence.
        public var display = Font.system(.largeTitle, design: .monospaced, weight: .bold)
        public var heading = Font.system(.title2, design: .monospaced, weight: .bold)
        public var subheading = Font.system(.headline, design: .monospaced, weight: .semibold)
        public var button = Font.system(.callout, design: .monospaced, weight: .semibold)
        public var label = Font.system(.caption, design: .monospaced, weight: .semibold)
        public var timer = Font.system(.largeTitle, design: .monospaced, weight: .bold)
            .monospacedDigit()

        public init() {}
    }
}

// MARK: - Corner style

/// A rectangle with one square notch cut from each corner.
///
/// This is the whole "rounded corner" vocabulary of the app: a real radius
/// would need anti-aliasing and would read as blurry next to pixel sprites.
public struct PixelCorner: InsettableShape {
    public var step: CGFloat
    private var insetAmount: CGFloat = 0

    public init(step: CGFloat = 3) {
        self.step = step
    }

    public func inset(by amount: CGFloat) -> PixelCorner {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    public func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard r.width > 0, r.height > 0 else { return Path() }
        let s = max(0, min(step, min(r.width, r.height) / 2))
        guard s > 0 else { return Path(r) }

        var path = Path()
        path.move(to: CGPoint(x: r.minX + s, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - s, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + s))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + s))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - s))
        path.addLine(to: CGPoint(x: r.maxX - s, y: r.maxY - s))
        path.addLine(to: CGPoint(x: r.maxX - s, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + s, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - s))
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY - s))
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + s))
        path.addLine(to: CGPoint(x: r.minX + s, y: r.minY + s))
        path.closeSubpath()
        return path
    }
}

// MARK: - Environment

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme()
}

extension EnvironmentValues {
    /// The active design tokens. Defaulted, so no view needs a provider above
    /// it just to render.
    public var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
