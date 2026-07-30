import MaikuKit
import SwiftUI

/// Plan §14: "If the app is prepared for public distribution, the About
/// screen must state that it is an independent project and not affiliated
/// with Anthropic." Presented as a sheet from Settings rather than the
/// system's own About panel, so it can say more than that panel's terse
/// name/version/copyright — the Clawd artwork status in particular.
struct AboutView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: theme.space.lg) {
            ClawdView(.idle, size: 96, showsCaption: false)

            VStack(spacing: theme.space.xs) {
                Text("maiku")
                    .font(theme.font.display)
                    .foregroundStyle(theme.color.textPrimary)
                Text("Version \(Self.version) (\(Self.build))")
                    .font(theme.font.caption)
                    .foregroundStyle(theme.color.textSecondary)
            }

            Text(
                "Local-first meeting notes. Recording, transcription, and speaker diarization all run on this Mac. Only transcript text you choose to organize is ever sent anywhere — to the LM Studio endpoint you configure, and nowhere else."
            )
            .font(theme.font.body)
            .foregroundStyle(theme.color.textPrimary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Text(
                "maiku is an independent project and is not affiliated with, endorsed by, or sponsored by Anthropic. The Clawd character belongs to Anthropic; any artwork shown, including AI-generated pieces, was supplied and individually authorized by the project maintainer, not scraped or traced from anyone else's work."
            )
            .font(theme.font.caption)
            .foregroundStyle(theme.color.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Button("Close") { dismiss() }
                .buttonStyle(.pixel(.secondary))
        }
        .padding(theme.space.xxl)
        .frame(width: 420)
        .background(theme.color.surface)
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }
}
