import SwiftUI

/// A segmented 8-bit progress bar, determinate or indeterminate.
///
/// One component covers both because the pipeline only sometimes knows a
/// fraction: chunk organization reports progress, model loading does not
/// (plan §10.5). Callers pass `nil` rather than faking a number.
public struct PixelProgress: View {
    @Environment(\.theme) private var theme
    @Environment(\.effectiveReduceMotion) private var reduceMotion

    private let value: Double?
    private let cells: Int
    private let height: CGFloat
    private let label: String

    /// - Parameters:
    ///   - value: 0…1, or `nil` for indeterminate. Out-of-range and NaN values
    ///     are clamped rather than trusted; they arrive from model callbacks.
    ///   - label: VoiceOver label; progress is never conveyed by the bar alone.
    public init(
        value: Double? = nil,
        cells: Int = 24,
        height: CGFloat = 12,
        label: String = "Progress"
    ) {
        self.value = value
        self.cells = max(1, cells)
        self.height = height
        self.label = label
    }

    public var body: some View {
        track
            .frame(height: height)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(valueDescription)
            .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder private var track: some View {
        if let value {
            let filled = Self.filledCells(value: value, cells: cells)
            bar(lit: (0..<cells).map { $0 < filled })
        } else if reduceMotion {
            // Reduce Motion: a static comb says "busy" without a marching block.
            bar(lit: (0..<cells).map { $0.isMultiple(of: 2) })
        } else {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let head = Self.head(at: context.date, cells: cells)
                bar(lit: (0..<cells).map { ($0 - head + cells) % cells < 4 })
            }
        }
    }

    private func bar(lit: [Bool]) -> some View {
        let shape = PixelCorner(step: theme.corner.small)
        let on = theme.color.accent
        let off = theme.color.surfaceSunken
        return Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            var onPath = Path()
            var offPath = Path()
            for (i, isOn) in lit.enumerated() {
                // Snap every edge to a whole point so no cell renders blurry.
                let x = (size.width * CGFloat(i) / CGFloat(lit.count)).rounded(.down)
                let next = (size.width * CGFloat(i + 1) / CGFloat(lit.count)).rounded(.down)
                let rect = CGRect(x: x, y: 0, width: max(1, next - x - 1), height: size.height)
                if isOn { onPath.addRect(rect) } else { offPath.addRect(rect) }
            }
            context.fill(offPath, with: .color(off))
            context.fill(onPath, with: .color(on))
        }
        .background(theme.color.surfaceSunken, in: shape)
        .overlay { shape.strokeBorder(theme.color.border, lineWidth: theme.border.hairline) }
    }

    private var valueDescription: String {
        guard let value else { return "In progress" }
        return "\(Int((Self.clamped(value) * 100).rounded())) percent"
    }

    /// How many cells a fraction lights. Clamps NaN and out-of-range input,
    /// which is why it is separate and tested.
    nonisolated public static func filledCells(value: Double, cells: Int) -> Int {
        Int((clamped(value) * Double(max(0, cells))).rounded())
    }

    nonisolated private static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }

    /// Leading cell of the indeterminate block at a point in time.
    nonisolated private static func head(at date: Date, cells: Int) -> Int {
        let ticks = Int(date.timeIntervalSinceReferenceDate * 10)
        return ((ticks % cells) + cells) % cells
    }
}
