import MaikuKit
import SwiftUI

/// Push destinations within Search's own `NavigationStack` (plan §11.1), the
/// same pattern `LibraryView` uses for its own column.
enum SearchRoute: Hashable {
    case detail(UUID)
}

struct SearchView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.theme) private var theme

    @State private var path: [SearchRoute] = []
    @State private var queryText = ""
    @State private var statusFilter: RecordingStatus?
    @State private var tagFilter: String?
    @State private var speakerFilter: String?
    @State private var useDateRange = false
    @State private var startDate = Date.now.addingTimeInterval(-30 * 24 * 3600)
    @State private var endDate = Date.now

    @State private var availableTags: [RecordingRepository.TagCount] = []
    @State private var availableSpeakers: [String] = []
    @State private var results: [RecordingRepository.SearchHit] = []
    @State private var searchError: MaikuError?

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Search")
                .navigationDestination(for: SearchRoute.self) { route in
                    switch route {
                    case .detail(let id): RecordingDetailView(recordingID: id)
                    }
                }
        }
        .task { await loadFilterOptions() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: theme.space.md) {
            TextField("Search recordings, transcripts, speakers, tags…", text: $queryText)
                .textFieldStyle(.plain)
                .font(theme.font.body)
                .padding(theme.space.sm)
                .background(theme.color.surfaceRaised, in: RoundedRectangle(cornerRadius: theme.corner.small))
                .onChange(of: queryText) { _, _ in Task { await runSearch() } }

            filterBar

            if let searchError {
                Text(searchError.message)
                    .font(theme.font.caption)
                    .foregroundStyle(theme.color.warning)
            }

            if results.isEmpty {
                emptyState
            } else {
                resultsList
            }
        }
        .padding(theme.space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.color.surface)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: theme.space.sm) {
                Picker("Status", selection: $statusFilter) {
                    Text("Any status").tag(RecordingStatus?.none)
                    ForEach(RecordingStatus.allCases, id: \.self) { status in
                        Text(Self.statusLabel(status)).tag(RecordingStatus?.some(status))
                    }
                }
                .onChange(of: statusFilter) { _, _ in Task { await runSearch() } }

                if !availableTags.isEmpty {
                    Picker("Tag", selection: $tagFilter) {
                        Text("Any tag").tag(String?.none)
                        ForEach(availableTags) { tag in
                            Text("\(tag.tag) (\(tag.recordingCount))").tag(String?.some(tag.tag))
                        }
                    }
                    .onChange(of: tagFilter) { _, _ in Task { await runSearch() } }
                }

                if !availableSpeakers.isEmpty {
                    Picker("Speaker", selection: $speakerFilter) {
                        Text("Any speaker").tag(String?.none)
                        ForEach(availableSpeakers, id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                    .onChange(of: speakerFilter) { _, _ in Task { await runSearch() } }
                }

                Toggle("Date range", isOn: $useDateRange)
                    .onChange(of: useDateRange) { _, _ in Task { await runSearch() } }
                if useDateRange {
                    DatePicker("From", selection: $startDate, displayedComponents: .date)
                        .labelsHidden()
                        .onChange(of: startDate) { _, _ in Task { await runSearch() } }
                    DatePicker("To", selection: $endDate, displayedComponents: .date)
                        .labelsHidden()
                        .onChange(of: endDate) { _, _ in Task { await runSearch() } }
                }
            }
        }
        .font(theme.font.body)
    }

    private var emptyState: some View {
        PixelPanel {
            Text(queryText.isEmpty && !hasActiveFilter ? "Type to search, or choose a filter to browse." : "No matches.")
                .font(theme.font.body)
                .foregroundStyle(theme.color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: theme.space.sm) {
                ForEach(results, id: \.recordingID) { hit in
                    Button { path.append(.detail(hit.recordingID)) } label: {
                        SearchResultRow(hit: hit)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var hasActiveFilter: Bool {
        statusFilter != nil || tagFilter != nil || speakerFilter != nil || useDateRange
    }

    private func loadFilterOptions() async {
        guard let appEnvironment else { return }
        availableTags = (try? await appEnvironment.repository.fetchAllTags()) ?? []
        availableSpeakers = (try? await appEnvironment.repository.fetchAllSpeakerNames()) ?? []
    }

    private func runSearch() async {
        guard let appEnvironment else { return }
        searchError = nil
        let filters = RecordingRepository.SearchFilters(
            status: statusFilter, speakerName: speakerFilter, tag: tagFilter,
            startDate: useDateRange ? Calendar.current.startOfDay(for: startDate) : nil,
            endDate: useDateRange ? endDate : nil)
        do {
            results = try await appEnvironment.repository.search(queryText, filters: filters)
        } catch {
            results = []
            searchError = (error as? MaikuError) ?? .databaseFailure("\(error)")
        }
    }

    private static func statusLabel(_ status: RecordingStatus) -> String {
        switch status {
        case .recording: "Recording"
        case .finalizingAudio, .finalTranscription, .finalDiarization, .organizingChunks, .organizingFinal:
            "Processing"
        case .complete: "Complete"
        case .failed: "Failed"
        case .trashed: "Trashed"
        }
    }
}

private struct SearchResultRow: View {
    @Environment(\.theme) private var theme
    let hit: RecordingRepository.SearchHit

    var body: some View {
        PixelPanel(raised: false) {
            VStack(alignment: .leading, spacing: theme.space.xs) {
                HStack {
                    Text(hit.titleSnippet.isEmpty ? "Untitled Recording" : hit.titleSnippet)
                        .font(theme.font.subheading)
                        .foregroundStyle(theme.color.textPrimary)
                    Spacer()
                    StatusBadge(status: hit.status)
                }
                if !hit.transcriptSnippet.isEmpty {
                    Text(hit.transcriptSnippet)
                        .font(theme.font.body)
                        .foregroundStyle(theme.color.textSecondary)
                        .lineLimit(2)
                }
                Text(Self.dateFormatter.string(from: hit.recordingStartedAt))
                    .font(theme.font.caption)
                    .foregroundStyle(theme.color.textSecondary)
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
