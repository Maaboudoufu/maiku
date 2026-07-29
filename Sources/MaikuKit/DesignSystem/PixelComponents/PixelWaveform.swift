import SwiftUI

/// A blocky level history drawn around a centre line (plan §10.4).
///
/// One `Canvas` rather than a stack of bar views: the audio capture service
/// pushes a new level 10–20 times a second, and rebuilding fifty view
/// identities at that rate is the difference between a calm meter and a busy
/// main thread (plan §18).
///
/// It never animates. The bars move because the data moves, so there is no
/// eased transition or idle shimmer to suppress under Reduce Motion — nothing
/// here interpolates between frames.
public struct PixelWaveform: View {
    @Environment(\.theme) private var theme

    private let levels: [Float]
    private let barCount: Int
    private let rows: Int

    /// - Parameters:
    ///   - levels: Normalized 0…1 levels, oldest first. Any length is
    ///     acceptable; only the newest `barCount` are drawn.
    ///   - rows: Quantisation steps per half-height. Fewer steps, chunkier bars.
    public init(levels: [Float], barCount: Int = 48, rows: Int = 8) {
        self.levels = levels
        self.barCount = barCount
        self.rows = max(1, rows)
    }

    public var body: some View {
        let bars = Self.bars(from: levels, count: barCount)
        let ink = theme.color.accent
        let baseline = theme.color.borderSubtle
        let steps = rows

        Canvas { context, size in
            guard !bars.isEmpty, size.width > 0, size.height > 0 else { return }
            let unit = max(1, (size.height / 2 / CGFloat(steps)).rounded(.down))
            let mid = (size.height / 2).rounded()

            context.fill(
                Path(CGRect(x: 0, y: mid, width: size.width, height: 1)),
                with: .color(baseline))

            var path = Path()
            for (i, level) in bars.enumerated() {
                let x = (size.width * CGFloat(i) / CGFloat(bars.count)).rounded(.down)
                let next = (size.width * CGFloat(i + 1) / CGFloat(bars.count)).rounded(.down)
                // At least one cell tall, so a silent input still reads as a line.
                let cells = max(1, (level * CGFloat(steps)).rounded())
                let half = cells * unit
                path.addRect(
                    CGRect(x: x, y: mid - half, width: max(1, next - x - 1), height: half * 2))
            }
            context.fill(path, with: .color(ink))
        }
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(((bars.last ?? 0) * 100).rounded())) percent")
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// The newest `count` levels, sanitized to 0…1 and left-padded with silence.
    ///
    /// Levels come off the audio thread, where a dropped buffer or a divide by
    /// zero can produce NaN; a NaN reaches `Path` as a corrupt rect, so it is
    /// filtered here rather than trusted.
    nonisolated public static func bars(from levels: [Float], count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let newest = levels.suffix(count).map { level -> CGFloat in
            guard level.isFinite else { return 0 }
            return CGFloat(min(max(level, 0), 1))
        }
        let padding = [CGFloat](repeating: 0, count: count - newest.count)
        return padding + newest
    }
}
