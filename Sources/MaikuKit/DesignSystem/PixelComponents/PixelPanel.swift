import SwiftUI

/// The app's only box: a hairline-bordered surface with stepped corners and an
/// optional hard shadow (plan §13.1).
///
/// Screens group content with this instead of inventing their own backgrounds,
/// which is what keeps every edge on the same 1pt line and the same corner step.
public struct PixelPanel<Content: View>: View {
    @Environment(\.theme) private var theme

    private let title: String?
    private let raised: Bool
    private let content: Content

    /// - Parameters:
    ///   - title: Rendered as a small uppercase header with a hairline rule.
    ///   - raised: A raised panel sits on the hard shadow; a sunken one is a
    ///     well for read-only content such as a transcript.
    public init(
        _ title: String? = nil,
        raised: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.raised = raised
        self.content = content()
    }

    public var body: some View {
        let shape = PixelCorner(step: theme.corner.large)
        let dx = raised ? theme.shadow.offset.width : 0
        let dy = raised ? theme.shadow.offset.height : 0

        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(theme.font.label)
                    .textCase(.uppercase)
                    .tracking(1)
                    .foregroundStyle(theme.color.textSecondary)
                    .padding(.horizontal, theme.space.md)
                    .padding(.vertical, theme.space.sm)
                    .accessibilityAddTraits(.isHeader)
                Rectangle()
                    .fill(theme.color.borderSubtle)
                    .frame(height: theme.border.hairline)
            }
            content
                .padding(theme.space.md)
        }
        .background(raised ? theme.color.surfaceRaised : theme.color.surfaceSunken, in: shape)
        .overlay { shape.strokeBorder(theme.color.border, lineWidth: theme.border.hairline) }
        .background { shape.fill(theme.shadow.color).offset(x: dx, y: dy) }
        // Reserve the shadow's room so neighbours do not overlap it.
        .padding(.trailing, dx)
        .padding(.bottom, dy)
    }
}
