import Foundation
import Testing

@testable import MaikuKit

@Suite("App paths")
struct AppPathsTests {

    @Test("A relative path round-trips through the data directory")
    func roundTrip() throws {
        let recordingID = UUID()
        let absolute = AppPaths.audioDirectory
            .appending(path: recordingID.uuidString)
            .appending(path: "capture.caf")
        let relative = try #require(AppPaths.relativePath(of: absolute))
        #expect(relative == "Audio/\(recordingID.uuidString)/capture.caf")
        #expect(AppPaths.absoluteURL(forRelativePath: relative) == absolute)
    }

    @Test("A path outside the data directory has no relative form")
    func outsideBaseDirectory() {
        #expect(AppPaths.relativePath(of: URL(fileURLWithPath: "/etc/passwd")) == nil)
    }

    @Test(
        "Traversal and absolute paths read back from the database are rejected",
        arguments: [
            "../etc/passwd",
            "Audio/../../../etc/passwd",
            "Audio/../../Logs/secret",
            "/etc/passwd",
            "",
            "Audio//capture.caf",
        ])
    func rejectsUnsafeRelativePaths(_ path: String) {
        #expect(AppPaths.absoluteURL(forRelativePath: path) == nil, "\(path) must not resolve")
    }

    @Test("An ordinary nested relative path is accepted")
    func acceptsOrdinaryPath() {
        #expect(AppPaths.absoluteURL(forRelativePath: "Audio/abc/capture.caf") != nil)
    }
}

@Suite("Recording repository")
struct RecordingRepositoryTests {

    private func makeRepository() throws -> RecordingRepository {
        RecordingRepository(dbManager: try DatabaseManager.openInMemory())
    }

    @Test("Migrations run clean against a fresh in-memory database")
    func migrationsRunClean() throws {
        _ = try DatabaseManager.openInMemory()
    }

    @Test("A recording with speakers and segments round-trips")
    func roundTrip() async throws {
        let repo = try makeRepository()
        let recording = Recording(title: "Standup", status: .complete, durationSeconds: 61.5)
        try await repo.save(recording)

        let speaker = Speaker(recordingID: recording.id, diarizerLabel: "1", customName: "Priya")
        try await repo.upsertSpeakers([speaker], recordingID: recording.id)

        let segment = TranscriptSegment(
            recordingID: recording.id, speakerID: speaker.id, startTime: 0, endTime: 2,
            text: "Let's get started.", isFinal: true, source: .final)
        try await repo.replaceSegments([segment], recordingID: recording.id)

        let fetchedRecording = try await repo.fetch(id: recording.id)
        #expect(fetchedRecording?.title == "Standup")
        #expect(fetchedRecording?.status == .complete)

        let fetchedSpeakers = try await repo.fetchSpeakers(recordingID: recording.id)
        #expect(fetchedSpeakers.map(\.displayName) == ["Priya"])

        let fetchedSegments = try await repo.fetchSegments(recordingID: recording.id)
        #expect(fetchedSegments.map(\.text) == ["Let's get started."])
        #expect(fetchedSegments.first?.speakerID == speaker.id)
    }

    @Test("Replacing segments preserves user edits and drops provisional ones")
    func replaceSegmentsPreservesUserEdits() async throws {
        let repo = try makeRepository()
        let recording = Recording(title: "Planning")
        try await repo.save(recording)

        let provisional = TranscriptSegment(
            recordingID: recording.id, startTime: 0, endTime: 1, text: "live guess",
            isFinal: false, source: .live)
        let edited = TranscriptSegment(
            recordingID: recording.id, startTime: 1, endTime: 2, text: "the user's correction",
            isFinal: false, source: .userEdited)
        try await repo.replaceSegments([provisional, edited], recordingID: recording.id)

        let final = TranscriptSegment(
            recordingID: recording.id, startTime: 0, endTime: 1, text: "final transcription",
            isFinal: true, source: .final)
        try await repo.replaceSegments([final], recordingID: recording.id)

        let remaining = try await repo.fetchSegments(recordingID: recording.id)
        let texts = Set(remaining.map(\.text))
        #expect(texts == ["the user's correction", "final transcription"])
        #expect(!texts.contains("live guess"))
    }

    @Test("An organized result round-trips as JSON")
    func organizedResultRoundTrip() async throws {
        let repo = try makeRepository()
        let recording = Recording(title: "Retro")
        try await repo.save(recording)

        let result = OrganizedRecording(
            title: "Retro", shortSummary: "Went well.", tags: ["retro", "team"])
        try await repo.saveOrganizedResult(result, recordingID: recording.id)

        let fetched = try await repo.fetchOrganizedResult(recordingID: recording.id)
        #expect(fetched?.title == "Retro")
        #expect(fetched?.tags == ["retro", "team"])
    }

    @Test("Search finds a recording by transcript text and by speaker name")
    func searchFindsByTranscriptAndSpeaker() async throws {
        let repo = try makeRepository()
        let recording = Recording(title: "Budget Review")
        try await repo.save(recording)

        let speaker = Speaker(recordingID: recording.id, diarizerLabel: "1", customName: "Alex Rivera")
        try await repo.upsertSpeakers([speaker], recordingID: recording.id)

        let segment = TranscriptSegment(
            recordingID: recording.id, speakerID: speaker.id, startTime: 0, endTime: 3,
            text: "We need to finalize the quarterly forecast.", isFinal: true, source: .final)
        try await repo.replaceSegments([segment], recordingID: recording.id)

        let byTranscript = try await repo.search("forecast")
        #expect(byTranscript.map(\.recordingID) == [recording.id])

        let bySpeaker = try await repo.search("Rivera")
        #expect(bySpeaker.map(\.recordingID) == [recording.id])

        let noMatch = try await repo.search("nonexistentXYZ")
        #expect(noMatch.isEmpty)
    }

    @Test("Filters narrow search by status, date, speaker, and tag")
    func searchFiltersNarrowResults() async throws {
        let repo = try makeRepository()

        let launch = Recording(
            title: "Launch Planning", status: .complete,
            recordingStartedAt: Date(timeIntervalSince1970: 1_000_000))
        try await repo.save(launch)
        let launchSpeaker = Speaker(recordingID: launch.id, diarizerLabel: "1", customName: "Priya")
        try await repo.upsertSpeakers([launchSpeaker], recordingID: launch.id)
        try await repo.saveOrganizedResult(
            OrganizedRecording(title: "Launch Planning", tags: ["launch", "roadmap"]), recordingID: launch.id)

        let retro = Recording(
            title: "Team Retro", status: .failed,
            recordingStartedAt: Date(timeIntervalSince1970: 2_000_000))
        try await repo.save(retro)
        let retroSpeaker = Speaker(recordingID: retro.id, diarizerLabel: "1", customName: "Jordan")
        try await repo.upsertSpeakers([retroSpeaker], recordingID: retro.id)
        try await repo.saveOrganizedResult(
            OrganizedRecording(title: "Team Retro", tags: ["retro"]), recordingID: retro.id)

        // Status alone, no text query.
        let failedOnly = try await repo.search("", filters: .init(status: .failed))
        #expect(failedOnly.map(\.recordingID) == [retro.id])

        // Date range alone.
        let beforeRetro = try await repo.search(
            "", filters: .init(endDate: Date(timeIntervalSince1970: 1_500_000)))
        #expect(beforeRetro.map(\.recordingID) == [launch.id])

        // Speaker alone.
        let byJordan = try await repo.search("", filters: .init(speakerName: "Jordan"))
        #expect(byJordan.map(\.recordingID) == [retro.id])

        // Tag alone — an exact match, "launch" must not also match "roadmap".
        let byTag = try await repo.search("", filters: .init(tag: "launch"))
        #expect(byTag.map(\.recordingID) == [launch.id])
        let byOtherTag = try await repo.search("", filters: .init(tag: "roadmap"))
        #expect(byOtherTag.map(\.recordingID) == [launch.id])

        // Text query plus a filter that rules out the otherwise-matching text hit.
        let titleWordButWrongStatus = try await repo.search("Retro", filters: .init(status: .complete))
        #expect(titleWordButWrongStatus.isEmpty)

        // No text and no filters: nothing, not "everything".
        let empty = try await repo.search("")
        #expect(empty.isEmpty)
    }

    @Test("fetchAllTags counts distinct recordings per tag and excludes trash")
    func fetchAllTagsCountsRecordings() async throws {
        let repo = try makeRepository()
        let first = Recording(title: "First")
        try await repo.save(first)
        try await repo.saveOrganizedResult(OrganizedRecording(title: "First", tags: ["launch"]), recordingID: first.id)

        let second = Recording(title: "Second")
        try await repo.save(second)
        try await repo.saveOrganizedResult(OrganizedRecording(title: "Second", tags: ["launch", "retro"]), recordingID: second.id)

        let trashed = Recording(title: "Trashed")
        try await repo.save(trashed)
        try await repo.saveOrganizedResult(OrganizedRecording(title: "Trashed", tags: ["launch"]), recordingID: trashed.id)
        try await repo.trash(id: trashed.id)

        let tags = try await repo.fetchAllTags()
        #expect(tags == [
            RecordingRepository.TagCount(tag: "launch", recordingCount: 2),
            RecordingRepository.TagCount(tag: "retro", recordingCount: 1),
        ])
    }

    @Test("fetchAllSpeakerNames returns distinct, non-nil names, excluding trash")
    func fetchAllSpeakerNamesIsDistinctAndExcludesTrash() async throws {
        let repo = try makeRepository()
        let meeting1 = Recording(title: "Meeting 1")
        try await repo.save(meeting1)
        try await repo.upsertSpeakers(
            [Speaker(recordingID: meeting1.id, diarizerLabel: "1", customName: "Priya"),
             Speaker(recordingID: meeting1.id, diarizerLabel: "2")],
            recordingID: meeting1.id)

        let meeting2 = Recording(title: "Meeting 2")
        try await repo.save(meeting2)
        try await repo.upsertSpeakers(
            [Speaker(recordingID: meeting2.id, diarizerLabel: "1", customName: "Priya")],
            recordingID: meeting2.id)

        let trashed = Recording(title: "Trashed Meeting")
        try await repo.save(trashed)
        try await repo.upsertSpeakers(
            [Speaker(recordingID: trashed.id, diarizerLabel: "1", customName: "Ghost")],
            recordingID: trashed.id)
        try await repo.trash(id: trashed.id)

        #expect(try await repo.fetchAllSpeakerNames() == ["Priya"])
    }

    @Test("Deleting a recording removes it from search")
    func deletionRemovesFromSearch() async throws {
        let repo = try makeRepository()
        let recording = Recording(title: "Ephemeral")
        try await repo.save(recording)
        let segment = TranscriptSegment(
            recordingID: recording.id, startTime: 0, endTime: 1, text: "unique-marker-token",
            isFinal: true, source: .final)
        try await repo.replaceSegments([segment], recordingID: recording.id)

        #expect(try await repo.search("unique-marker-token").isEmpty == false)
        try await repo.deletePermanently(id: recording.id)
        #expect(try await repo.search("unique-marker-token").isEmpty)
        #expect(try await repo.fetch(id: recording.id) == nil)
    }

    @Test("Deleting a recording cascades to its speakers and segments")
    func deletionCascades() async throws {
        let repo = try makeRepository()
        let recording = Recording(title: "Cascade Test")
        try await repo.save(recording)
        let speaker = Speaker(recordingID: recording.id, diarizerLabel: "1")
        try await repo.upsertSpeakers([speaker], recordingID: recording.id)
        let segment = TranscriptSegment(
            recordingID: recording.id, startTime: 0, endTime: 1, text: "hello", isFinal: true,
            source: .final)
        try await repo.replaceSegments([segment], recordingID: recording.id)

        try await repo.deletePermanently(id: recording.id)

        #expect(try await repo.fetchSpeakers(recordingID: recording.id).isEmpty)
        #expect(try await repo.fetchSegments(recordingID: recording.id).isEmpty)
        #expect(try await repo.fetchOrganizedResult(recordingID: recording.id) == nil)
    }

    @Test("Trashing sets status and trashedAt without deleting data")
    func trashSetsStatus() async throws {
        let repo = try makeRepository()
        let recording = Recording(title: "To Trash")
        try await repo.save(recording)

        try await repo.trash(id: recording.id)

        let fetched = try await repo.fetch(id: recording.id)
        #expect(fetched?.status == .trashed)
        #expect(fetched?.trashedAt != nil)

        let active = try await repo.fetchAll(includeTrashed: false)
        #expect(active.isEmpty)
        let all = try await repo.fetchAll(includeTrashed: true)
        #expect(all.map(\.id) == [recording.id])
    }

    @Test("Interrupted recordings are exactly those in a non-terminal status")
    func fetchInterruptedFindsNonTerminalStatuses() async throws {
        let repo = try makeRepository()
        let recording = Recording(title: "Complete", status: .complete)
        try await repo.save(recording)
        let failed = Recording(title: "Failed", status: .failed)
        try await repo.save(failed)
        let trashedOne = Recording(title: "Trashed", status: .trashed)
        try await repo.save(trashedOne)

        var interruptedIDs: [UUID] = []
        for status in [
            RecordingStatus.recording, .finalizingAudio, .finalTranscription, .finalDiarization,
            .organizingChunks, .organizingFinal,
        ] {
            let interrupted = Recording(title: "Interrupted \(status.rawValue)", status: status)
            try await repo.save(interrupted)
            interruptedIDs.append(interrupted.id)
        }

        let found = try await repo.fetchInterrupted()
        #expect(Set(found.map(\.id)) == Set(interruptedIDs))
        #expect(!found.contains { $0.id == recording.id })
        #expect(!found.contains { $0.id == failed.id })
        #expect(!found.contains { $0.id == trashedOne.id })
    }

    @Test("Renaming a speaker updates the search index too")
    func renameSpeakerUpdatesSearch() async throws {
        let repo = try makeRepository()
        let recording = Recording(title: "Rename Test")
        try await repo.save(recording)
        let speaker = Speaker(recordingID: recording.id, diarizerLabel: "1")
        try await repo.upsertSpeakers([speaker], recordingID: recording.id)

        try await repo.renameSpeaker(id: speaker.id, to: "Morgan Lee")

        let renamed = try await repo.fetchSpeakers(recordingID: recording.id)
        #expect(renamed.first?.displayName == "Morgan Lee")
        #expect(try await repo.search("Morgan").map(\.recordingID) == [recording.id])
    }
}

@Suite("Settings store")
struct SettingsStoreTests {

    private func makeStore() throws -> SettingsStore {
        SettingsStore(dbManager: try DatabaseManager.openInMemory())
    }

    @Test("Fetching before any save returns AppSettings defaults")
    func fetchDefaultsWhenNoRowSaved() async throws {
        let store = try makeStore()
        #expect(try await store.fetch() == AppSettings())
    }

    @Test("Saved settings round-trip, including nil-able fields")
    func roundTrip() async throws {
        let store = try makeStore()
        var settings = AppSettings()
        settings.inputDeviceUID = "BuiltInMicrophoneDevice"
        settings.speechModelName = "base.en"
        settings.language = "en"
        settings.liveDiarizationEnabled = false
        settings.lmStudioBaseURL = URL(string: "http://127.0.0.1:5678")!
        settings.lmStudioModelID = "qwen2.5-7b"
        settings.lmStudioTimeout = 45
        settings.audioRetentionDays = 30
        settings.reducedMotionOverride = true
        settings.soundEffectsEnabled = false
        settings.crtEffectsEnabled = false

        try await store.save(settings)

        #expect(try await store.fetch() == settings)
    }

    @Test("A second save replaces the singleton row rather than inserting another")
    func secondSaveReplacesRow() async throws {
        let store = try makeStore()
        try await store.save(AppSettings(speechModelName: "tiny.en"))
        try await store.save(AppSettings(speechModelName: "large-v3_turbo"))

        let fetched = try await store.fetch()
        #expect(fetched.speechModelName == "large-v3_turbo")
    }
}

@Suite("Keychain token store")
struct KeychainTokenStoreTests {

    private func makeStore() -> KeychainTokenStore {
        KeychainTokenStore(service: "com.maiku.Maiku.tests.\(UUID().uuidString)", account: "apiToken")
    }

    @Test("No token is stored until one is saved")
    func nilBeforeSave() throws {
        let store = makeStore()
        defer { try? store.clear() }
        #expect(try store.token() == nil)
    }

    @Test("A saved token round-trips")
    func roundTrip() throws {
        let store = makeStore()
        defer { try? store.clear() }
        try store.save("sk-test-token")
        #expect(try store.token() == "sk-test-token")
    }

    @Test("Saving again overwrites the previous token")
    func overwritesExisting() throws {
        let store = makeStore()
        defer { try? store.clear() }
        try store.save("first-token")
        try store.save("second-token")
        #expect(try store.token() == "second-token")
    }

    @Test("Saving nil clears a previously stored token")
    func savingNilClears() throws {
        let store = makeStore()
        defer { try? store.clear() }
        try store.save("a-token")
        try store.save(nil)
        #expect(try store.token() == nil)
    }
}
