import MaikuKit
import SwiftUI

@main
struct MaikuApp: App {
    var body: some Scene {
        WindowGroup("maiku") {
            RootView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
    }
}

/// `NavigationSplitView` shell (plan §10.1). Library is the only destination
/// with a real screen behind it in Milestone 1; the others are honest
/// placeholders rather than buttons that pretend to do something they don't —
/// Search, Tags, Trash and full Settings land in Milestone 5.
struct RootView: View {
    @State private var destination: AppDestination? = .library
    @State private var appEnvironment: AppEnvironment?
    @State private var launchError: MaikuError?
    @State private var interruptedRecordings: [Recording] = []

    var body: some View {
        Group {
            if let appEnvironment {
                if !interruptedRecordings.isEmpty {
                    RecoveryView(interrupted: $interruptedRecordings)
                        .environment(\.appEnvironment, appEnvironment)
                } else {
                    NavigationSplitView {
                        List(AppDestination.allCases, id: \.self, selection: $destination) { item in
                            Label(item.title, systemImage: item.systemImage)
                        }
                        .navigationSplitViewColumnWidth(min: 180, ideal: 200)
                    } detail: {
                        destinationView(for: destination ?? .library)
                    }
                    .environment(\.appEnvironment, appEnvironment)
                }
            } else if let launchError {
                LaunchErrorView(error: launchError)
            } else {
                ProgressView("Starting maiku…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            do {
                let environment = try AppEnvironment()
                appEnvironment = environment
                // Plan §9: check for anything the app never finished
                // processing before showing the Library at all.
                interruptedRecordings = (try? await environment.recoveryService.detectInterrupted()) ?? []
            } catch {
                launchError = (error as? MaikuError) ?? .databaseFailure("\(error)")
            }
        }
    }

    @ViewBuilder
    private func destinationView(for destination: AppDestination) -> some View {
        switch destination {
        case .library:
            LibraryView()
        case .search, .tags, .trash, .settings:
            ComingLaterView(destination: destination)
        }
    }
}

private struct LaunchErrorView: View {
    @Environment(\.theme) private var theme
    let error: MaikuError

    var body: some View {
        VStack(spacing: theme.space.md) {
            ClawdView(.error, size: 96)
            Text("maiku could not start")
                .font(theme.font.heading)
                .foregroundStyle(theme.color.textPrimary)
            Text(error.message)
                .font(theme.font.body)
                .foregroundStyle(theme.color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(theme.space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color.surface)
    }
}

private struct ComingLaterView: View {
    @Environment(\.theme) private var theme
    let destination: AppDestination

    var body: some View {
        VStack(spacing: theme.space.sm) {
            Text(destination.title)
                .font(theme.font.heading)
                .foregroundStyle(theme.color.textPrimary)
            Text("Arrives in a later milestone.")
                .font(theme.font.body)
                .foregroundStyle(theme.color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color.surface)
    }
}

enum AppDestination: String, CaseIterable, Hashable {
    case library, search, tags, trash, settings

    var title: String {
        switch self {
        case .library: "Library"
        case .search: "Search"
        case .tags: "Tags"
        case .trash: "Trash"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .library: "waveform"
        case .search: "magnifyingglass"
        case .tags: "tag"
        case .trash: "trash"
        case .settings: "gearshape"
        }
    }
}
