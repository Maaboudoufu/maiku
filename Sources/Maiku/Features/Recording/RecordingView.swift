import MaikuKit
import SwiftUI

struct RecordingView: View {
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
            ClawdView(mascotState(coordinator), size: 140)

            Text(Self.timeString(coordinator.metrics.elapsed))
                .font(theme.font.timer)
                .foregroundStyle(theme.color.textPrimary)
                .accessibilityLabel("Elapsed time \(Self.timeString(coordinator.metrics.elapsed))")

            HStack(spacing: theme.space.sm) {
                Circle()
                    .fill(theme.color.recording)
                    .frame(width: 10, height: 10)
                    .opacity(coordinator.state == .recording ? 1 : 0.3)
                Text(coordinator.state == .paused ? "Paused" : "Recording")
                    .font(theme.font.label)
                    .foregroundStyle(theme.color.textSecondary)
            }
            .accessibilityElement(children: .combine)

            Text("You're responsible for any consent required to record this conversation.")
                .font(theme.font.caption)
                .foregroundStyle(theme.color.textSecondary)
                .multilineTextAlignment(.center)

            PixelWaveform(levels: coordinator.metrics.waveform)
                .frame(height: 72)

            transcriptPanel(coordinator)

            if let error = coordinator.lastError {
                ErrorBanner(error: error)
            }

            controls(coordinator)
        }
        .padding(theme.space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color.surface)
        .navigationTitle("Recording")
        .navigationBarBackButtonHidden(coordinator.state.isCapturingAudio)
        .onChange(of: coordinator.state) { _, newState in
            if case .processing = newState, path.last != .processing {
                path.append(.processing)
            }
        }
    }

    private func mascotState(_ coordinator: RecordingCoordinator) -> ClawdState {
        switch coordinator.state {
        case .paused: .paused
        case .recording: .listening(level: coordinator.metrics.level)
        default: .listening(level: 0)
        }
    }

    private func transcriptPanel(_ coordinator: RecordingCoordinator) -> some View {
        // Provisional "who spoke when" (plan §6.4): computed fresh from the
        // live segments and turns rather than stored, since it is never
        // more than a display concern — no Speaker rows exist yet, and the
        // file-based pass after stop replaces all of this outright.
        let labels = SpeakerAlignmentService.labels(
            for: coordinator.liveSegments, turns: coordinator.liveSpeakerTurns)
        return PixelPanel("Live Transcript", raised: false) {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.xs) {
                    if coordinator.liveSegments.isEmpty && coordinator.liveUnstableText.isEmpty {
                        Text("Listening…")
                            .font(theme.font.body)
                            .foregroundStyle(theme.color.textSecondary)
                    }
                    ForEach(Array(zip(coordinator.liveSegments, labels)), id: \.0.id) { segment, label in
                        VStack(alignment: .leading, spacing: theme.space.xxs) {
                            if let label {
                                Text("Speaker \(label)")
                                    .font(theme.font.label)
                                    .foregroundStyle(theme.color.accent)
                            }
                            Text(segment.text)
                                .font(theme.font.body)
                                .foregroundStyle(theme.color.textPrimary)
                        }
                    }
                    if !coordinator.liveUnstableText.isEmpty {
                        // Provisional text (plan §6.3): visually distinguished,
                        // not colour alone — the label below states it too.
                        Text(coordinator.liveUnstableText)
                            .font(theme.font.body)
                            .foregroundStyle(theme.color.textSecondary)
                            .italic()
                            .accessibilityLabel("Provisional: \(coordinator.liveUnstableText)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func controls(_ coordinator: RecordingCoordinator) -> some View {
        HStack(spacing: theme.space.md) {
            if coordinator.state == .recording {
                Button("Pause") {
                    Task { await coordinator.pauseRecording() }
                }
                .buttonStyle(PixelButtonStyle(.secondary))
            } else if coordinator.state == .paused {
                Button("Resume") {
                    Task { try? await coordinator.resumeRecording() }
                }
                .buttonStyle(PixelButtonStyle(.secondary))
            }

            Button("Stop") {
                Task { await coordinator.stopRecording() }
            }
            .buttonStyle(PixelButtonStyle(.record))
            .disabled(!coordinator.state.isCapturingAudio)
        }
    }

    private static func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
