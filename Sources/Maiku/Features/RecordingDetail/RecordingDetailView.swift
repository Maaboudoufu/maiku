import MaikuKit
import SwiftUI

/// Plan §10.6: header, a persistent compact audio player, speaker editor,
/// and the Overview / Notes / Transcript / Action Items tabs. Transcript
/// segments and quotes seek the player when clicked, and the segment
/// currently playing is highlighted (plan §4.11, §10.6).
struct RecordingDetailView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.theme) private var theme
    let recordingID: UUID

    private enum Tab: String, CaseIterable, Hashable {
        case overview = "Overview"
        case notes = "Notes"
        case transcript = "Transcript"
        case actionItems = "Action Items"
    }

    @State private var recording: Recording?
    @State private var segments: [TranscriptSegment] = []
    @State private var speakers: [Speaker] = []
    @State private var organized: OrganizedRecording?
    @State private var tab: Tab = .overview
    @State private var titleDraft = ""
    @State private var isRetrying = false
    @State private var retryError: MaikuError?

    @State private var playback = AudioPlaybackService()
    @State private var playbackState = PlaybackState(currentTime: 0, duration: 0, isPlaying: false, rate: 1)
    @State private var playbackError: MaikuError?

    var body: some View {
        Group {
            if let recording {
                detail(recording)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: recordingID) {
            await load()
            await loadAudio()
        }
        .task(id: recordingID) {
            for await state in playback.state {
                playbackState = state
            }
        }
    }

    @ViewBuilder
    private func detail(_ recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(recording)
            if recording.workingAudioRelativePath != nil || recording.audioRelativePath != nil {
                PlayerBar(
                    state: playbackState, error: playbackError,
                    onTogglePlay: { Task { await togglePlay() } },
                    onScrub: { time in Task { await playback.seek(to: time) } },
                    onSetRate: { rate in Task { await playback.setRate(rate) } })
                    .padding(.horizontal, theme.space.lg)
                    .padding(.bottom, theme.space.md)
            }
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, theme.space.lg)
            .padding(.bottom, theme.space.md)

            ScrollView {
                Group {
                    switch tab {
                    case .overview: overview
                    case .notes: notes
                    case .transcript: transcriptTab
                    case .actionItems: actionItemsTab
                    }
                }
                .padding(theme.space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.color.surface)
        .navigationTitle(recording.title.isEmpty ? "Recording" : recording.title)
    }

    private func header(_ recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: theme.space.sm) {
            TextField("Title", text: $titleDraft)
                .font(theme.font.heading)
                .textFieldStyle(.plain)
                .onSubmit { Task { await saveTitle() } }

            HStack(spacing: theme.space.md) {
                Text(Self.dateFormatter.string(from: recording.recordingStartedAt))
                Text(Self.durationString(recording.durationSeconds))
                StatusBadge(status: recording.status)
            }
            .font(theme.font.caption)
            .foregroundStyle(theme.color.textSecondary)

            if let organized, !organized.tags.isEmpty {
                TagRow(tags: organized.tags)
            }
        }
        .padding(theme.space.lg)
    }

    // MARK: Overview

    @ViewBuilder
    private var overview: some View {
        VStack(alignment: .leading, spacing: theme.space.md) {
            if let organized {
                if !organized.shortSummary.isEmpty {
                    PixelPanel("Summary") {
                        Text(organized.shortSummary)
                            .font(theme.font.body)
                            .foregroundStyle(theme.color.textPrimary)
                    }
                }
                if !organized.keyTakeaways.isEmpty {
                    PixelPanel("Key Takeaways") {
                        BulletList(items: organized.keyTakeaways.map(\.text))
                    }
                }
                if !organized.decisions.isEmpty {
                    PixelPanel("Decisions") {
                        BulletList(items: organized.decisions.map(\.text))
                    }
                }
                speakerEditor
            } else {
                notOrganizedYet
            }
        }
    }

    /// Two distinct failure shapes land here, and need two distinct retries:
    /// a recording that reached `.complete` but whose organize step failed
    /// (transcript and speakers are good — re-run only LM Studio), versus one
    /// stuck in `.failed` because an earlier stage never finished (transcript
    /// may not exist at all — re-run the whole pipeline, not just notes).
    private var notOrganizedYet: some View {
        let pipelineFailed = recording?.status == .failed
        return VStack(alignment: .leading, spacing: theme.space.md) {
            PixelPanel {
                VStack(alignment: .leading, spacing: theme.space.sm) {
                    Text(
                        pipelineFailed
                            ? "Processing didn't finish."
                            : recording?.errorStage != nil
                                ? "Note generation didn't finish."
                                : "Notes have not been generated for this recording yet.")
                    .font(theme.font.body)
                    .foregroundStyle(theme.color.textPrimary)
                    if let message = recording?.errorMessage {
                        Text(message)
                            .font(theme.font.caption)
                            .foregroundStyle(theme.color.textSecondary)
                    }
                    if let retryError {
                        ErrorBanner(error: retryError)
                    }
                    Button(isRetrying ? "Retrying…" : (pipelineFailed ? "Retry Processing" : "Retry Organization")) {
                        Task { pipelineFailed ? await retryProcessing() : await retryOrganization() }
                    }
                    .buttonStyle(PixelButtonStyle(.primary))
                    .disabled(isRetrying)
                }
            }
            speakerEditor
        }
    }

    private var speakerEditor: some View {
        PixelPanel("Speakers") {
            if speakers.isEmpty {
                Text("No speakers identified.")
                    .font(theme.font.body)
                    .foregroundStyle(theme.color.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: theme.space.sm) {
                    ForEach(speakers) { speaker in
                        SpeakerRenameRow(
                            speaker: speaker,
                            colorIndex: speaker.colorIndex,
                            onRename: { newName in await renameSpeaker(speaker, to: newName) })
                    }
                }
            }
        }
    }

    // MARK: Notes

    @ViewBuilder
    private var notes: some View {
        if let organized, !organized.organizedSections.isEmpty {
            VStack(alignment: .leading, spacing: theme.space.md) {
                ForEach(organized.organizedSections) { section in
                    PixelPanel(section.heading) {
                        EditableSectionBody(
                            text: section.body,
                            onEdit: { newBody in await editNotesSection(section, newBody: newBody) })
                    }
                }
                if !organized.openQuestions.isEmpty {
                    PixelPanel("Open Questions") {
                        BulletList(items: organized.openQuestions.map(\.text))
                    }
                }
                if !organized.quotes.isEmpty {
                    PixelPanel("Quotes") {
                        VStack(alignment: .leading, spacing: theme.space.xs) {
                            ForEach(organized.quotes) { quote in
                                QuoteRow(quote: quote) { Task { await seekAndPlay(to: quote.startTime) } }
                            }
                        }
                    }
                }
            }
        } else {
            emptyTabMessage("No organized notes yet.")
        }
    }

    // MARK: Transcript

    @ViewBuilder
    private var transcriptTab: some View {
        if segments.isEmpty {
            emptyTabMessage("No transcript yet.")
        } else {
            VStack(alignment: .leading, spacing: theme.space.sm) {
                ForEach(segments) { segment in
                    TranscriptRow(
                        segment: segment, speakerName: speakerName(for: segment.speakerID),
                        isCurrent: isCurrentlyPlaying(segment),
                        onTap: { Task { await seekAndPlay(to: segment.startTime) } },
                        onEdit: { newText in await editSegment(segment, newText: newText) })
                }
            }
        }
    }

    /// The segment `playbackState.currentTime` falls within, while playing —
    /// used to highlight it in the transcript (plan §10.6).
    private func isCurrentlyPlaying(_ segment: TranscriptSegment) -> Bool {
        playbackState.isPlaying && playbackState.currentTime >= segment.startTime
            && playbackState.currentTime < segment.endTime
    }

    // MARK: Action items

    @ViewBuilder
    private var actionItemsTab: some View {
        if let organized, !organized.actionItems.isEmpty {
            VStack(alignment: .leading, spacing: theme.space.sm) {
                ForEach(organized.actionItems) { item in
                    PixelPanel(raised: false) {
                        VStack(alignment: .leading, spacing: theme.space.xs) {
                            Text(item.task)
                                .font(theme.font.body)
                                .foregroundStyle(theme.color.textPrimary)
                            HStack(spacing: theme.space.sm) {
                                if let owner = item.ownerText ?? speakerName(for: item.ownerSpeakerID) {
                                    Label(owner, systemImage: "person.fill")
                                }
                                if let due = item.dueDateISO8601 {
                                    Label(due, systemImage: "calendar")
                                }
                            }
                            .font(theme.font.caption)
                            .foregroundStyle(theme.color.textSecondary)
                        }
                    }
                }
            }
        } else {
            emptyTabMessage("No action items identified.")
        }
    }

    private func emptyTabMessage(_ text: String) -> some View {
        Text(text)
            .font(theme.font.body)
            .foregroundStyle(theme.color.textSecondary)
    }

    private func speakerName(for id: UUID?) -> String? {
        guard let id else { return nil }
        return speakers.first { $0.id == id }?.displayName
    }

    // MARK: Data

    private func load() async {
        guard let repository = appEnvironment?.repository else { return }
        async let fetchedRecording = repository.fetch(id: recordingID)
        async let fetchedSegments = repository.fetchSegments(recordingID: recordingID)
        async let fetchedSpeakers = repository.fetchSpeakers(recordingID: recordingID)
        async let fetchedOrganized = repository.fetchOrganizedResult(recordingID: recordingID)

        recording = try? await fetchedRecording
        segments = (try? await fetchedSegments) ?? []
        speakers = (try? await fetchedSpeakers) ?? []
        organized = try? await fetchedOrganized
        titleDraft = recording?.title ?? ""
    }

    private func saveTitle() async {
        guard var recording, let repository = appEnvironment?.repository, !titleDraft.isEmpty else { return }
        recording.title = titleDraft
        recording.updatedAt = Date()
        self.recording = recording
        try? await repository.save(recording)
    }

    private func renameSpeaker(_ speaker: Speaker, to name: String) async {
        guard let repository = appEnvironment?.repository else { return }
        do {
            try await repository.renameSpeaker(id: speaker.id, to: name)
            speakers = try await repository.fetchSpeakers(recordingID: recordingID)
        } catch {}
    }

    /// Marks the edited segment `.userEdited` so a future re-transcription
    /// (plan §6.5 step 6, "Retry Processing") preserves this text instead of
    /// overwriting it. `RecordingRepository.replaceSegments` already knows
    /// how to keep a `.userEdited` segment across a wholesale replacement;
    /// passing the whole array back reuses that rather than adding a
    /// separate single-segment update path for what is, on this screen, an
    /// infrequent edit against a small list.
    private func editSegment(_ segment: TranscriptSegment, newText: String) async {
        guard let repository = appEnvironment?.repository,
            let index = segments.firstIndex(where: { $0.id == segment.id }),
            newText != segment.text
        else { return }
        segments[index].text = newText
        segments[index].source = .userEdited
        try? await repository.replaceSegments(segments, recordingID: recordingID)
    }

    /// Plan §10.6's "Editable sections" — `OrganizedRecording` is stored as
    /// one JSON blob (see the `ponytail:` note on `organizedResults` in
    /// `Migrations.swift`), so an edit re-saves the whole thing rather than
    /// one section in isolation; at this screen's scale that's an
    /// unmeasurable cost, not a real one.
    private func editNotesSection(_ section: OrganizedSection, newBody: String) async {
        guard let repository = appEnvironment?.repository, var organized,
            let index = organized.organizedSections.firstIndex(where: { $0.id == section.id }),
            newBody != section.body
        else { return }
        organized.organizedSections[index].body = newBody
        self.organized = organized
        try? await repository.saveOrganizedResult(organized, recordingID: recordingID)
    }

    // MARK: Playback

    private func loadAudio() async {
        guard let recording,
            let relativePath = recording.audioRelativePath ?? recording.workingAudioRelativePath,
            let url = AppPaths.absoluteURL(forRelativePath: relativePath)
        else { return }
        do {
            try await playback.load(url: url)
            playbackError = nil
        } catch {
            playbackError = (error as? MaikuError) ?? .fileIntegrityCheckFailed(path: relativePath)
        }
    }

    private func togglePlay() async {
        do {
            if playbackState.isPlaying {
                await playback.pause()
            } else {
                try await playback.play()
            }
            playbackError = nil
        } catch {
            playbackError = (error as? MaikuError) ?? .audioEngineFailed("\(error)")
        }
    }

    /// Plan §4.11/§10.6: clicking a transcript segment or quote jumps to,
    /// and starts, its audio — not merely cueing a paused player.
    private func seekAndPlay(to time: TimeInterval) async {
        await playback.seek(to: time)
        do {
            try await playback.play()
            playbackError = nil
        } catch {
            playbackError = (error as? MaikuError) ?? .audioEngineFailed("\(error)")
        }
    }

    private func retryOrganization() async {
        guard let recording, let coordinator = appEnvironment?.coordinator else { return }
        isRetrying = true
        retryError = nil
        defer { isRetrying = false }
        do {
            try await coordinator.retryOrganization(for: recording)
            await load()
        } catch {
            retryError = (error as? MaikuError) ?? .databaseFailure("\(error)")
        }
    }

    /// A `.failed` recording — an earlier stage never finished, not just
    /// notes — needs the whole pipeline re-run, not just LM Studio.
    private func retryProcessing() async {
        guard let recording, let coordinator = appEnvironment?.coordinator else { return }
        isRetrying = true
        retryError = nil
        defer { isRetrying = false }
        do {
            if coordinator.state == .idle {
                try await coordinator.prepareModels(speechModel: SpeechModelConfiguration(modelName: "tiny.en"))
            }
            try await coordinator.recoverAndProcess(recording)
            await load()
        } catch {
            retryError = (error as? MaikuError) ?? .databaseFailure("\(error)")
        }
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

private struct BulletList: View {
    @Environment(\.theme) private var theme
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, text in
                HStack(alignment: .top, spacing: theme.space.xs) {
                    Text("•").foregroundStyle(theme.color.accent)
                    Text(text)
                        .font(theme.font.body)
                        .foregroundStyle(theme.color.textPrimary)
                }
            }
        }
    }
}

private struct TagRow: View {
    @Environment(\.theme) private var theme
    let tags: [String]

    var body: some View {
        HStack(spacing: theme.space.xs) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(theme.font.label)
                    .foregroundStyle(theme.color.textSecondary)
                    .padding(.horizontal, theme.space.sm)
                    .padding(.vertical, theme.space.xxs)
                    .background(theme.color.surfaceSunken, in: PixelCorner(step: theme.corner.small))
            }
        }
    }
}

/// Plan §10.6's "Editable sections". Same commit-on-focus-loss pattern as
/// `TranscriptRow`'s text field, for the same reason: `axis: .vertical` lets
/// Return insert a newline instead of submitting on macOS, and a multi-
/// sentence note section is exactly the kind of text that needs to wrap.
private struct EditableSectionBody: View {
    @Environment(\.theme) private var theme
    let text: String
    let onEdit: (String) async -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Section text", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(theme.font.body)
            .foregroundStyle(theme.color.textPrimary)
            .focused($isFocused)
            .onSubmit { Task { await onEdit(draft) } }
            .onChange(of: isFocused) { wasFocused, nowFocused in
                if wasFocused, !nowFocused { Task { await onEdit(draft) } }
            }
            .onChange(of: text, initial: true) { _, newValue in draft = newValue }
    }
}

private struct TranscriptRow: View {
    @Environment(\.theme) private var theme
    let segment: TranscriptSegment
    let speakerName: String?
    let isCurrent: Bool
    let onTap: () -> Void
    let onEdit: (String) async -> Void

    @State private var textDraft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: theme.space.sm) {
            Button(action: onTap) {
                Text(Self.timestamp(segment.startTime))
                    .font(theme.font.label)
                    .foregroundStyle(isCurrent ? theme.color.accent : theme.color.textSecondary)
                    .frame(width: 56, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play from \(Self.timestamp(segment.startTime))")

            VStack(alignment: .leading, spacing: theme.space.xxs) {
                if let speakerName {
                    Text(speakerName)
                        .font(theme.font.label)
                        .foregroundStyle(theme.color.accent)
                }
                // Plan §10.6 "Inline editing" — always an editable field
                // rather than a separate edit mode, since a transcript
                // correction is a one-line change, not a workflow.
                //
                // Committing on submit alone is not enough: `axis: .vertical`
                // lets Return insert a newline instead of submitting, so
                // losing focus is the one commit path guaranteed to fire.
                TextField("Transcript text", text: $textDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(theme.font.body)
                    .foregroundStyle(theme.color.textPrimary)
                    .focused($isFocused)
                    .onSubmit { Task { await onEdit(textDraft) } }
                    .onChange(of: isFocused) { wasFocused, nowFocused in
                        if wasFocused, !nowFocused { Task { await onEdit(textDraft) } }
                    }
                    .onChange(of: segment.text, initial: true) { _, newValue in textDraft = newValue }
            }
        }
        .padding(.vertical, theme.space.xs)
        .padding(.horizontal, theme.space.sm)
        .background(
            isCurrent ? theme.color.surfaceSunken : Color.clear,
            in: PixelCorner(step: theme.corner.small)
        )
        .accessibilityElement(children: .combine)
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct QuoteRow: View {
    @Environment(\.theme) private var theme
    let quote: ImportantQuote
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: theme.space.xs) {
                Text(Self.timestamp(quote.startTime))
                    .font(theme.font.label)
                    .foregroundStyle(theme.color.textSecondary)
                    .frame(width: 44, alignment: .leading)
                Text("“\(quote.exactText)”")
                    .font(theme.font.body)
                    .foregroundStyle(theme.color.textPrimary)
                    .multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Quote at \(Self.timestamp(quote.startTime)): \(quote.exactText)")
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct PlayerBar: View {
    @Environment(\.theme) private var theme
    let state: PlaybackState
    let error: MaikuError?
    let onTogglePlay: @Sendable () -> Void
    let onScrub: @Sendable (TimeInterval) -> Void
    let onSetRate: @Sendable (Float) -> Void

    private static let rates: [Float] = [0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        PixelPanel(raised: false) {
            VStack(alignment: .leading, spacing: theme.space.xs) {
                HStack(spacing: theme.space.sm) {
                    Button(action: onTogglePlay) {
                        Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(PixelButtonStyle(.secondary))
                    .accessibilityLabel(state.isPlaying ? "Pause" : "Play")

                    Text(Self.timeString(state.currentTime))
                        .font(theme.font.label)
                        .foregroundStyle(theme.color.textSecondary)
                        .frame(width: 44, alignment: .trailing)
                        .monospacedDigit()

                    Slider(
                        value: Binding(get: { state.currentTime }, set: onScrub),
                        in: 0...max(state.duration, 0.01)
                    )
                    .tint(theme.color.accent)
                    .accessibilityLabel("Playback position")

                    Text(Self.timeString(state.duration))
                        .font(theme.font.label)
                        .foregroundStyle(theme.color.textSecondary)
                        .frame(width: 44, alignment: .leading)
                        .monospacedDigit()

                    Menu {
                        ForEach(Self.rates, id: \.self) { rate in
                            Button(Self.rateLabel(rate)) { onSetRate(rate) }
                        }
                    } label: {
                        Text(Self.rateLabel(state.rate))
                            .font(theme.font.label)
                    }
                    .fixedSize()
                    .accessibilityLabel("Playback speed, currently \(Self.rateLabel(state.rate))")
                }
                if let error {
                    ErrorBanner(error: error)
                }
            }
        }
    }

    private static func timeString(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func rateLabel(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%.2g×", rate)
    }
}

private struct SpeakerRenameRow: View {
    @Environment(\.theme) private var theme
    let speaker: Speaker
    let colorIndex: Int
    let onRename: (String) async -> Void

    @State private var name: String = ""

    var body: some View {
        HStack(spacing: theme.space.sm) {
            Circle()
                .fill(theme.color.speaker(at: colorIndex))
                .frame(width: 10, height: 10)
            TextField(speaker.displayName, text: $name)
                .textFieldStyle(.plain)
                .font(theme.font.body)
                .onSubmit { Task { await onRename(name) } }
        }
        .onAppear { name = speaker.customName ?? speaker.displayName }
    }
}
