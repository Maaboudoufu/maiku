import MaikuKit
import SwiftUI

struct ProcessingView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.theme) private var theme
    @Binding var path: [LibraryRoute]

    var body: some View {
        if let coordinator = appEnvironment?.coordinator {
            content(coordinator)
        }
    }

    @ViewBuilder
    private func content(_ coordinator: RecordingCoordinator) -> some View {
        VStack(spacing: theme.space.lg) {
            ClawdView(mascotState(coordinator.state), size: 140)
            stageList(current: currentStage(coordinator.state))
            if case .failed(_, let message) = coordinator.state {
                ErrorBanner(error: coordinator.lastError ?? .databaseFailure(message))
                Button("Back to Library") { path = [] }
                    .buttonStyle(PixelButtonStyle(.secondary))
            } else {
                Text("You can leave this screen — processing continues in the background.")
                    .font(theme.font.caption)
                    .foregroundStyle(theme.color.textSecondary)
            }
        }
        .padding(theme.space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color.surface)
        .navigationTitle("Processing")
        .onChange(of: coordinator.state) { _, newState in
            if case .complete = newState, let id = coordinator.currentRecording?.id {
                path = [.detail(id)]
            }
        }
    }

    private func mascotState(_ state: RecordingState) -> ClawdState {
        switch state {
        case .processing(.organizingChunks), .processing(.organizingFinal): .organizing(progress: nil)
        case .processing: .transcribing
        case .failed: .error
        default: .organizing(progress: nil)
        }
    }

    private func currentStage(_ state: RecordingState) -> ProcessingStage? {
        if case .processing(let stage) = state { return stage }
        return nil
    }

    private func stageList(current: ProcessingStage?) -> some View {
        PixelPanel("Stages") {
            VStack(alignment: .leading, spacing: theme.space.sm) {
                ForEach(ProcessingStage.allCases, id: \.self) { stage in
                    HStack(spacing: theme.space.sm) {
                        Image(systemName: icon(for: stage, current: current))
                            .foregroundStyle(color(for: stage, current: current))
                            .frame(width: 16)
                        Text(stage.displayName)
                            .font(theme.font.body)
                            .foregroundStyle(color(for: stage, current: current))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func stageIndex(_ stage: ProcessingStage) -> Int? {
        ProcessingStage.allCases.firstIndex(of: stage)
    }

    private func icon(for stage: ProcessingStage, current: ProcessingStage?) -> String {
        guard let current, let i = stageIndex(stage), let c = stageIndex(current) else {
            return "circle"
        }
        if i < c { return "checkmark.circle.fill" }
        if i == c { return "arrow.triangle.2.circlepath" }
        return "circle"
    }

    private func color(for stage: ProcessingStage, current: ProcessingStage?) -> Color {
        guard let current, let i = stageIndex(stage), let c = stageIndex(current) else {
            return theme.color.textSecondary
        }
        return i <= c ? theme.color.textPrimary : theme.color.textSecondary
    }
}
