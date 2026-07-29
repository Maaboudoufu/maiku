import SwiftUI

/// 8-bit button chrome.
///
/// This is a `ButtonStyle` rather than a bespoke view so that plain `Button`s
/// keep their focus ring, keyboard activation, `.disabled` handling and
/// VoiceOver traits for free (plan §13.2).
public struct PixelButtonStyle: ButtonStyle {
    public enum Role: Sendable, Equatable {
        case primary
        case secondary
        /// Red, and only for actions that destroy data.
        case destructive
        /// Red, and only for starting or stopping a live capture.
        case record
    }

    public var role: Role
    public var fillsWidth: Bool

    public init(_ role: Role = .primary, fillsWidth: Bool = false) {
        self.role = role
        self.fillsWidth = fillsWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        Chrome(role: role, fillsWidth: fillsWidth, configuration: configuration)
    }

    /// A nested view, because a `ButtonStyle` itself cannot read the
    /// environment.
    private struct Chrome: View {
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var isEnabled

        let role: Role
        let fillsWidth: Bool
        let configuration: ButtonStyleConfiguration

        var body: some View {
            let shape = PixelCorner(step: theme.corner.medium)
            let pressed = configuration.isPressed && isEnabled
            let dx = isEnabled ? theme.shadow.offset.width : 0
            let dy = isEnabled ? theme.shadow.offset.height : 0

            configuration.label
                .font(theme.font.button)
                .textCase(.uppercase)
                .tracking(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, theme.space.lg)
                .padding(.vertical, theme.space.sm)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .background(background, in: shape)
                .overlay {
                    shape.strokeBorder(theme.color.border, lineWidth: theme.border.hairline)
                }
                .offset(x: pressed ? dx : 0, y: pressed ? dy : 0)
                .background {
                    // The hard shadow the button "lifts off"; pressing sits the
                    // button down onto it.
                    shape.fill(theme.shadow.color)
                        .offset(x: dx, y: dy)
                        .opacity(pressed ? 0 : 1)
                }
                // Reserve the shadow's room so neighbouring views do not overlap it.
                .padding(.trailing, dx)
                .padding(.bottom, dy)
                .contentShape(Rectangle())
        }

        private var background: Color {
            guard isEnabled else { return theme.color.surfaceSunken }
            return switch role {
            case .primary: configuration.isPressed ? theme.color.accentPressed : theme.color.accent
            case .secondary: theme.color.surfaceRaised
            case .destructive: theme.color.destructive
            case .record: theme.color.recording
            }
        }

        private var foreground: Color {
            guard isEnabled else { return theme.color.textSecondary }
            return switch role {
            case .primary: theme.color.onAccent
            case .secondary: theme.color.textPrimary
            case .destructive, .record: theme.color.onDanger
            }
        }
    }
}

extension ButtonStyle where Self == PixelButtonStyle {
    public static var pixel: PixelButtonStyle { PixelButtonStyle() }

    public static func pixel(_ role: PixelButtonStyle.Role, fillsWidth: Bool = false)
        -> PixelButtonStyle
    {
        PixelButtonStyle(role, fillsWidth: fillsWidth)
    }
}
