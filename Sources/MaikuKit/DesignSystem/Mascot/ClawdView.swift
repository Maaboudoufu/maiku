import SwiftUI

/// The mascot, in whatever state the app is in (plan §14).
///
/// If authorised artwork is installed the manifest's frames are drawn with
/// nearest-neighbour scaling. If it is not — which is the case in this
/// repository, because the Clawd character is Anthropic's — a clearly labelled
/// generic pixel creature stands in. The placeholder renders every state and
/// runs the same frame sequences, so nothing downstream has to change when real
/// art arrives.
public struct ClawdView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let state: ClawdState
    private let size: CGFloat
    private let showsCaption: Bool

    /// - Parameter showsCaption: The state's word under the sprite. On by
    ///   default: a picture must not be the only carrier of state (plan §13.2).
    public init(_ state: ClawdState, size: CGFloat = 96, showsCaption: Bool = true) {
        self.state = state
        self.size = size
        self.showsCaption = showsCaption
    }

    public var body: some View {
        VStack(spacing: theme.space.xs) {
            sprite
            if showsCaption {
                Text(state.caption)
                    .font(theme.font.label)
                    .textCase(.uppercase)
                    .tracking(1)
                    .foregroundStyle(theme.color.textSecondary)
            }
            if !ClawdArtwork.isInstalled { placeholderBadge }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel)
        .accessibilityValue(state.accessibilityValue ?? "")
    }

    @ViewBuilder private var sprite: some View {
        let entry = ClawdAssetManifest.standard.entry(for: state)
        if reduceMotion || entry.frames.count <= 1 {
            // Reduce Motion: hold the first frame. The caption and the VoiceOver
            // label still say what is happening.
            frame(entry, index: 0)
        } else {
            TimelineView(.periodic(from: .now, by: entry.frameDuration)) { context in
                frame(entry, index: Self.frameIndex(at: context.date, entry: entry))
            }
        }
    }

    @ViewBuilder private func frame(_ entry: ClawdAssetManifest.Entry, index: Int) -> some View {
        let name: String? = entry.frames.indices.contains(index) ? entry.frames[index] : nil
        if let name, let image = ClawdArtwork.image(name) {
            // ponytail: nearest-neighbour keeps edges hard at any size, but a
            // size that is not a multiple of 64 makes some source pixels one
            // point wider than others. Callers use multiples of 64 (see
            // Resources/Clawd/README.md); snap the frame here if real art ever
            // has to live in an odd-sized box.
            image
                .interpolation(.none)  // no blurry scaled pixel art (plan §13.1)
                .antialiased(false)
                .resizable()
                .frame(width: size, height: size)
        } else {
            PlaceholderSprite(state: state, frameIndex: index)
                .frame(width: size, height: size)
        }
    }

    private var placeholderBadge: some View {
        Text("Placeholder art")
            .font(theme.font.label)
            .textCase(.uppercase)
            .tracking(1)
            .foregroundStyle(theme.color.textSecondary)
            .padding(.horizontal, theme.space.xs)
            .padding(.vertical, theme.space.xxs)
            .overlay {
                PixelCorner(step: theme.corner.small)
                    .strokeBorder(theme.color.borderSubtle, lineWidth: theme.border.hairline)
            }
            // The caption above already names the state; this is a note to the
            // developer, not something VoiceOver should repeat per mascot.
            .accessibilityHidden(true)
    }

    /// Which frame the sequence is showing at a given instant. Derived from the
    /// clock rather than held in `@State`, so no timer has to be cancelled.
    nonisolated static func frameIndex(at date: Date, entry: ClawdAssetManifest.Entry) -> Int {
        let count = entry.frames.count
        guard count > 1, entry.frameDuration > 0 else { return 0 }
        let ticks = Int(date.timeIntervalSinceReferenceDate / entry.frameDuration)
        return ((ticks % count) + count) % count
    }
}

// MARK: - Placeholder

/// A deliberately generic pixel blob with a per-state prop.
///
/// This is not Clawd and is not meant to become the product's mascot: it exists
/// so the state machine, the animation timing and the accessibility wiring are
/// all real and testable while the repository legitimately has no artwork
/// (plan §14 asset rule).
private struct PlaceholderSprite: View {
    @Environment(\.theme) private var theme

    let state: ClawdState
    let frameIndex: Int

    /// 16×16 cells, matching `ClawdAssetManifest.spriteSize` at 4px per cell.
    private static let gridSize = 16

    var body: some View {
        let palette: [Character: Color] = [
            "#": theme.color.border,
            "O": theme.color.accent,
            "+": theme.color.textSecondary,
            "=": theme.color.success,
            "!": theme.color.recording,
            "~": theme.color.warning,
        ]
        let fallback = theme.color.textPrimary
        let creature = Self.creature
        let prop = Self.prop(for: state)
        // A one-cell bob is the whole placeholder animation; real art replaces it.
        let bob = frameIndex.isMultiple(of: 2) ? 0 : -1
        let extras = Self.extraCells(for: state, frameIndex: frameIndex)
        let grid = Self.gridSize

        Canvas { context, size in
            let unit = max(1, (min(size.width, size.height) / CGFloat(grid)).rounded(.down))
            let originX = ((size.width - unit * CGFloat(grid)) / 2).rounded(.down)
            let originY = ((size.height - unit * CGFloat(grid)) / 2).rounded(.down)

            // One path per colour: a state draws ~120 cells and filling them
            // individually would mean 120 draw calls a frame.
            var paths: [Character: Path] = [:]
            func plot(_ column: Int, _ row: Int, _ ink: Character) {
                guard (0..<grid).contains(column), (0..<grid).contains(row) else { return }
                paths[ink, default: Path()].addRect(
                    CGRect(
                        x: originX + CGFloat(column) * unit,
                        y: originY + CGFloat(row) * unit,
                        width: unit, height: unit))
            }

            for (row, line) in creature.enumerated() {
                for (column, ink) in line.enumerated() where ink != "." {
                    plot(column, row + 5, ink)
                }
            }
            for (row, line) in prop.enumerated() {
                for (column, ink) in line.enumerated() where ink != "." {
                    plot(11 + column, row + 8 + bob, ink)
                }
            }
            for cell in extras { plot(cell.column, cell.row, cell.ink) }

            for (ink, path) in paths {
                context.fill(path, with: .color(palette[ink] ?? fallback))
            }
        }
    }

    /// 10×10. `#` outline, `O` body.
    private static let creature = [
        "...####...",
        "..#OOOO#..",
        ".#OOOOOO#.",
        "#OO#OO#OO#",
        "#OOOOOOOO#",
        "#OO####OO#",
        ".#OOOOOO#.",
        ".#OOOOOO#.",
        "..#O##O#..",
        "..#.##.#..",
    ]

    /// 5×5 prop, one per state — the shape, not the colour, is what
    /// distinguishes the states (plan §13.2).
    private static func prop(for state: ClawdState) -> [String] {
        switch state {
        case .idle:  // notebook
            [".###.", "#+++#", "#+++#", "#+++#", ".###."]
        case .ready:  // microphone on a stand
            ["..#..", ".#O#.", ".#O#.", "..#..", ".###."]
        case .listening:  // microphone, live
            ["..#..", ".#!#.", ".#O#.", "..#..", ".###."]
        case .paused:  // pause bars
            ["##.##", "##.##", "##.##", "##.##", "##.##"]
        case .transcribing:  // tiny terminal
            ["#####", "#+..#", "#++.#", "#####", ".###."]
        case .organizing:  // note cards going into a folder
            ["..###", ".###+", "###+.", "#++..", "###.."]
        case .complete:  // checkmark
            ["....=", "...=.", "=.=..", ".=...", "....."]
        case .error:  // microphone with a severed cable
            ["..#..", ".#O#.", "..#..", ".~..~", "~..~."]
        case .lmStudioDisconnected:  // computer with an unplugged lead
            ["#####", "#+++#", "#####", "..#..", ".~.~."]
        }
    }

    private struct Cell {
        let column: Int
        let row: Int
        let ink: Character
    }

    /// Cells that depend on the state's payload rather than on a fixed grid:
    /// the sound waves above the microphone while listening.
    private static func extraCells(for state: ClawdState, frameIndex: Int) -> [Cell] {
        guard case .listening(let level) = state else { return [] }
        let amplitude = level.isFinite ? min(max(level, 0), 1) : 0
        let tallest = 1 + Int(amplitude * 3)
        return (0..<3).flatMap { bar -> [Cell] in
            let height = max(1, tallest - (frameIndex + bar) % 3)
            return (0..<height).map { Cell(column: 11 + bar * 2, row: 6 - $0, ink: "!") }
        }
    }
}
