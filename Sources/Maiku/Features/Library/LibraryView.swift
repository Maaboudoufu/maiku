import MaikuKit
import SwiftUI

/// Push destinations within the Library column's own `NavigationStack`
/// (nested inside `RootView`'s outer `NavigationSplitView`, the standard
/// macOS pattern for push navigation within one split-view column).
enum LibraryRoute: Hashable {
    case recording
    case processing
    case detail(UUID)
}

struct LibraryView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.theme) private var theme

    @State private var path: [LibraryRoute] = []
    @State private var recordings: [Recording] = []
    @State private var isPreparingModels = false
    @State private var setupError: MaikuError?

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Library")
                .navigationDestination(for: LibraryRoute.self) { route in
                    switch route {
                    case .recording:
                        RecordingView(path: $path)
                    case .processing:
                        ProcessingView(path: $path)
                    case .detail(let id):
                        RecordingDetailView(recordingID: id)
                    }
                }
        }
        .task { await refresh() }
        .onChange(of: path) { _, newPath in
            if newPath.isEmpty { Task { await refresh() } }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: theme.space.lg) {
            header
            if let setupError {
                ErrorBanner(error: setupError)
            }
            if recordings.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .padding(theme.space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.color.surface)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: theme.space.xs) {
                Text("maiku")
                    .font(theme.font.display)
                    .foregroundStyle(theme.color.textPrimary)
                Text("Local-first meeting notes.")
                    .font(theme.font.secondary)
                    .foregroundStyle(theme.color.textSecondary)
            }
            Spacer()
            recordButton
        }
    }

    private var recordButton: some View {
        Button {
            Task { await startRecording() }
        } label: {
            HStack(spacing: theme.space.sm) {
                if isPreparingModels {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "record.circle.fill")
                }
                Text(isPreparingModels ? "Preparing…" : "Record")
            }
        }
        .buttonStyle(PixelButtonStyle(.record))
        .disabled(isPreparingModels || (appEnvironment?.coordinator.state.isCapturingAudio ?? false))
    }

    private var emptyState: some View {
        PixelPanel {
            VStack(spacing: theme.space.sm) {
                ClawdView(.idle, size: 72, showsCaption: false)
                Text("No recordings yet")
                    .font(theme.font.subheading)
                    .foregroundStyle(theme.color.textPrimary)
                Text("Press Record to capture a conversation, transcribe it, and organize the notes.")
                    .font(theme.font.body)
                    .foregroundStyle(theme.color.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 420)
            .padding(theme.space.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: theme.space.sm) {
                ForEach(recordings) { recording in
                    Button { path.append(.detail(recording.id)) } label: {
                        RecordingCard(recording: recording)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func refresh() async {
        guard let repository = appEnvironment?.repository else { return }
        recordings = (try? await repository.fetchAll()) ?? []
    }

    private func startRecording() async {
        guard let coordinator = appEnvironment?.coordinator else { return }
        setupError = nil
        do {
            try await MicrophonePermission.request()
            if coordinator.state == .idle {
                isPreparingModels = true
                defer { isPreparingModels = false }
                try await coordinator.prepareModels(speechModel: SpeechModelConfiguration(modelName: "tiny.en"))
            }
            try await coordinator.startRecording()
            path.append(.recording)
        } catch {
            setupError = (error as? MaikuError) ?? .audioEngineFailed("\(error)")
        }
    }
}

private struct RecordingCard: View {
    @Environment(\.theme) private var theme
    let recording: Recording

    var body: some View {
        PixelPanel(raised: false) {
            HStack(alignment: .top, spacing: theme.space.md) {
                VStack(alignment: .leading, spacing: theme.space.xs) {
                    Text(recording.title.isEmpty ? "Untitled Recording" : recording.title)
                        .font(theme.font.subheading)
                        .foregroundStyle(theme.color.textPrimary)
                    Text(Self.dateFormatter.string(from: recording.recordingStartedAt))
                        .font(theme.font.caption)
                        .foregroundStyle(theme.color.textSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: theme.space.xs) {
                    Text(Self.durationString(recording.durationSeconds))
                        .font(theme.font.label)
                        .foregroundStyle(theme.color.textSecondary)
                    StatusBadge(status: recording.status)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func durationString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct StatusBadge: View {
    @Environment(\.theme) private var theme
    let status: RecordingStatus

    var body: some View {
        Text(label)
            .font(theme.font.label)
            .textCase(.uppercase)
            .foregroundStyle(color)
            .accessibilityLabel(Text("Status: \(label)"))
    }

    private var label: String {
        switch status {
        case .recording: "Recording"
        case .finalizingAudio, .finalTranscription, .finalDiarization, .organizingChunks,
            .organizingFinal:
            "Processing"
        case .complete: "Complete"
        case .failed: "Failed"
        case .trashed: "Trashed"
        }
    }

    private var color: Color {
        switch status {
        case .recording: theme.color.recording
        case .failed: theme.color.warning
        case .complete: theme.color.success
        default: theme.color.textSecondary
        }
    }
}

struct ErrorBanner: View {
    @Environment(\.theme) private var theme
    let error: MaikuError

    var body: some View {
        PixelPanel(raised: false) {
            HStack(alignment: .top, spacing: theme.space.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.color.warning)
                Text(error.message)
                    .font(theme.font.body)
                    .foregroundStyle(theme.color.textPrimary)
            }
        }
    }
}
