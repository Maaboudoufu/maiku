import MaikuKit
import SwiftUI

/// Plan §9's recovery screen: shown before the Library whenever
/// `RecoveryService.detectInterrupted()` finds a recording maiku never
/// finished processing — the app was killed, crashed, or the machine lost
/// power while one was active. Audio is always safe; this just asks what to
/// do with it.
struct RecoveryView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.theme) private var theme

    @Binding var interrupted: [Recording]

    @State private var busyID: UUID?
    @State private var error: MaikuError?

    var body: some View {
        VStack(spacing: theme.space.lg) {
            ClawdView(.error, size: 96)
            VStack(spacing: theme.space.xs) {
                Text(
                    interrupted.count == 1
                        ? "1 interrupted recording"
                        : "\(interrupted.count) interrupted recordings"
                )
                .font(theme.font.heading)
                .foregroundStyle(theme.color.textPrimary)
                Text("maiku closed unexpectedly while these were being recorded or processed. Your audio is safe.")
                    .font(theme.font.body)
                    .foregroundStyle(theme.color.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let error {
                ErrorBanner(error: error)
            }
            ScrollView {
                VStack(spacing: theme.space.sm) {
                    ForEach(interrupted) { recording in
                        RecoveryRow(
                            recording: recording,
                            isBusy: busyID == recording.id,
                            isDisabled: busyID != nil,
                            onRecover: { await resolve(recording) { try await recoverAndProcess($0) } },
                            onKeepAudio: { await resolve(recording) { try await appEnvironment?.coordinator.keepAudioOnly($0) } },
                            onDelete: { await resolve(recording) { try await appEnvironment?.recoveryService.deletePermanently($0) } })
                    }
                }
            }
        }
        .padding(theme.space.xxl)
        .frame(maxWidth: 560, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .background(theme.color.surface)
    }

    /// Prepares the speech models first if this is the first thing the user
    /// does this launch — same lazy-preparation pattern `LibraryView` uses
    /// for a fresh recording, since `recoverAndProcess` needs a loaded
    /// transcriber just as much as a live recording does.
    private func recoverAndProcess(_ recording: Recording) async throws {
        guard let appEnvironment else { return }
        let coordinator = appEnvironment.coordinator
        if coordinator.state == .idle {
            let settings = (try? await appEnvironment.settingsStore.fetch()) ?? AppSettings()
            try await coordinator.prepareModels(
                speechModel: settings.speechModel, liveDiarizationEnabled: settings.liveDiarizationEnabled)
        }
        try await coordinator.recoverAndProcess(recording)
    }

    private func resolve(_ recording: Recording, _ action: (Recording) async throws -> Void) async {
        busyID = recording.id
        error = nil
        do {
            try await action(recording)
            interrupted.removeAll { $0.id == recording.id }
        } catch {
            self.error = (error as? MaikuError) ?? .databaseFailure("\(error)")
        }
        busyID = nil
    }
}

private struct RecoveryRow: View {
    @Environment(\.theme) private var theme
    let recording: Recording
    let isBusy: Bool
    let isDisabled: Bool
    let onRecover: () async -> Void
    let onKeepAudio: () async -> Void
    let onDelete: () async -> Void

    var body: some View {
        PixelPanel(raised: false) {
            VStack(alignment: .leading, spacing: theme.space.sm) {
                HStack {
                    VStack(alignment: .leading, spacing: theme.space.xxs) {
                        Text(recording.title.isEmpty ? "Untitled Recording" : recording.title)
                            .font(theme.font.subheading)
                            .foregroundStyle(theme.color.textPrimary)
                        Text(Self.dateFormatter.string(from: recording.recordingStartedAt))
                            .font(theme.font.caption)
                            .foregroundStyle(theme.color.textSecondary)
                    }
                    Spacer()
                    if isBusy {
                        ProgressView().controlSize(.small)
                    }
                }
                HStack(spacing: theme.space.sm) {
                    Button("Recover and Process") { Task { await onRecover() } }
                        .buttonStyle(PixelButtonStyle(.primary))
                    Button("Keep Audio Only") { Task { await onKeepAudio() } }
                        .buttonStyle(PixelButtonStyle(.secondary))
                    Button("Delete") { Task { await onDelete() } }
                        .buttonStyle(PixelButtonStyle(.destructive))
                }
                .disabled(isDisabled)
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
