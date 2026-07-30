import MaikuKit
import SwiftUI

/// Push destinations within Tags' own `NavigationStack` (plan §16 Milestone
/// 5: "List distinct tags across recordings with counts; tapping one shows
/// matching recordings").
enum TagsRoute: Hashable {
    case recordings(String)
    case detail(UUID)
}

struct TagsView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.theme) private var theme

    @State private var path: [TagsRoute] = []
    @State private var tags: [RecordingRepository.TagCount] = []
    @State private var loadError: MaikuError?

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Tags")
                .navigationDestination(for: TagsRoute.self) { route in
                    switch route {
                    case .recordings(let tag):
                        TagRecordingsView(tag: tag, path: $path)
                    case .detail(let id):
                        RecordingDetailView(recordingID: id)
                    }
                }
        }
        .task { await load() }
        .onChange(of: path) { _, newPath in
            if newPath.isEmpty { Task { await load() } }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: theme.space.lg) {
            if let loadError {
                Text(loadError.message)
                    .font(theme.font.body)
                    .foregroundStyle(theme.color.warning)
            }
            if tags.isEmpty {
                PixelPanel {
                    Text("No tags yet. Organized recordings gain tags automatically.")
                        .font(theme.font.body)
                        .foregroundStyle(theme.color.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: theme.space.sm) {
                        ForEach(tags) { tag in
                            Button { path.append(.recordings(tag.tag)) } label: {
                                TagRow(tag: tag)
                            }
                            .buttonStyle(.plain)
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
        do {
            tags = try await appEnvironment.repository.fetchAllTags()
            loadError = nil
        } catch {
            loadError = (error as? MaikuError) ?? .databaseFailure("\(error)")
        }
    }
}

private struct TagRow: View {
    @Environment(\.theme) private var theme
    let tag: RecordingRepository.TagCount

    var body: some View {
        PixelPanel(raised: false) {
            HStack {
                Text(tag.tag)
                    .font(theme.font.subheading)
                    .foregroundStyle(theme.color.textPrimary)
                Spacer()
                Text("\(tag.recordingCount)")
                    .font(theme.font.label)
                    .foregroundStyle(theme.color.textSecondary)
                    .accessibilityHidden(true)
                // Decorative — the row is already a Button; a bare "chevron
                // forward" adds nothing VoiceOver needs beyond that trait.
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(theme.color.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(tag.tag), \(tag.recordingCount) recording\(tag.recordingCount == 1 ? "" : "s")")
    }
}

private struct TagRecordingsView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.theme) private var theme
    let tag: String
    @Binding var path: [TagsRoute]

    @State private var hits: [RecordingRepository.SearchHit] = []

    var body: some View {
        ScrollView {
            LazyVStack(spacing: theme.space.sm) {
                ForEach(hits, id: \.recordingID) { hit in
                    Button { path.append(.detail(hit.recordingID)) } label: {
                        PixelPanel(raised: false) {
                            HStack {
                                Text(hit.titleSnippet.isEmpty ? "Untitled Recording" : hit.titleSnippet)
                                    .font(theme.font.subheading)
                                    .foregroundStyle(theme.color.textPrimary)
                                Spacer()
                                StatusBadge(status: hit.status)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(theme.space.lg)
        }
        .background(theme.color.surface)
        .navigationTitle(tag)
        .task { await load() }
    }

    private func load() async {
        guard let appEnvironment else { return }
        hits = (try? await appEnvironment.repository.search("", filters: .init(tag: tag))) ?? []
    }
}
