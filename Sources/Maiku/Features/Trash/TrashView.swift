import MaikuKit
import SwiftUI

/// Plan §16 Milestone 5: "Trash and permanent deletion." Restoring is a
/// plain repository update; permanent deletion goes through
/// `RecoveryService.deletePermanently`, the one place that already removes
/// both the database rows and the audio directory together.
struct TrashView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.theme) private var theme

    @State private var trashed: [Recording] = []
    @State private var busyID: UUID?
    @State private var pendingDelete: Recording?
    @State private var actionError: MaikuError?

    var body: some View {
        content
            .navigationTitle("Trash")
            .task { await load() }
            .confirmationDialog(
                "Delete Permanently?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                presenting: pendingDelete
            ) { recording in
                Button("Delete Permanently", role: .destructive) {
                    Task { await deletePermanently(recording) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { recording in
                Text("\"\(recording.title.isEmpty ? "Untitled Recording" : recording.title)\" and its audio will be removed for good. This cannot be undone.")
            }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: theme.space.lg) {
            if let actionError {
                Text(actionError.message)
                    .font(theme.font.body)
                    .foregroundStyle(theme.color.warning)
            }
            if trashed.isEmpty {
                PixelPanel {
                    Text("Trash is empty.")
                        .font(theme.font.body)
                        .foregroundStyle(theme.color.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: theme.space.sm) {
                        ForEach(trashed) { recording in
                            TrashRow(
                                recording: recording,
                                isBusy: busyID == recording.id,
                                onRestore: { Task { await restore(recording) } },
                                onDeletePermanently: { pendingDelete = recording })
                        }
                    }
                }
            }
        }
        .padding(theme.space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.color.surface)
    }

    private func load() async {
        guard let appEnvironment else { return }
        trashed = (try? await appEnvironment.repository.fetchTrashed()) ?? []
    }

    private func restore(_ recording: Recording) async {
        guard let appEnvironment else { return }
        busyID = recording.id
        actionError = nil
        do {
            try await appEnvironment.repository.restore(id: recording.id)
            await load()
        } catch {
            actionError = (error as? MaikuError) ?? .databaseFailure("\(error)")
        }
        busyID = nil
    }

    private func deletePermanently(_ recording: Recording) async {
        guard let appEnvironment else { return }
        busyID = recording.id
        actionError = nil
        do {
            try await appEnvironment.recoveryService.deletePermanently(recording)
            await load()
        } catch {
            actionError = (error as? MaikuError) ?? .databaseFailure("\(error)")
        }
        busyID = nil
    }
}

private struct TrashRow: View {
    @Environment(\.theme) private var theme
    let recording: Recording
    let isBusy: Bool
    let onRestore: () -> Void
    let onDeletePermanently: () -> Void

    var body: some View {
        PixelPanel(raised: false) {
            HStack(alignment: .top, spacing: theme.space.md) {
                VStack(alignment: .leading, spacing: theme.space.xs) {
                    Text(recording.title.isEmpty ? "Untitled Recording" : recording.title)
                        .font(theme.font.subheading)
                        .foregroundStyle(theme.color.textPrimary)
                    if let trashedAt = recording.trashedAt {
                        Text("Trashed \(Self.dateFormatter.string(from: trashedAt))")
                            .font(theme.font.caption)
                            .foregroundStyle(theme.color.textSecondary)
                    }
                }
                Spacer()
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Restore", action: onRestore)
                        .buttonStyle(.pixel(.secondary))
                    Button("Delete Permanently", action: onDeletePermanently)
                        .buttonStyle(.pixel(.destructive))
                }
            }
        }
        .disabled(isBusy)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
