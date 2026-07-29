import AVFoundation
import Foundation
import Testing

@testable import MaikuKit

/// `RecordingCoordinator.startRecording()` writes through the real,
/// production `AppPaths.audioDirectory(for:)` — there is no injection seam
/// for that path, only for the capture session itself — so any test that
/// calls it leaves a directory under the real
/// `~/Library/Application Support/Maiku/Audio/` unless it cleans up
/// explicitly. Each recording gets its own random UUID, so this can never
/// collide with real user data; it just has to not be left behind.
private func cleanUpTestAudio(for recordingID: UUID) {
    try? FileManager.default.removeItem(
        at: AppPaths.audioDirectory.appending(path: recordingID.uuidString))
}

// MARK: - Fakes
//
// `AudioCapturing` is the seam that makes this suite possible at all: the
// concrete `AudioCaptureService` needs a real microphone, so
// `RecordingCoordinator` takes a factory closure instead of constructing one
// itself. `SpeechTranscribing`/`SpeakerDiarizing` were already behind
// protocols. `LMStudioClient` stays concrete but already accepts an injected
// `URLSession`, so it runs for real against `StubURLProtocol` (the same
// mock server `LMStudioTests.swift` uses — reused here rather than
// reinvented, since this suite is exercising the coordinator's pipeline, not
// LM Studio's own decoding, which is already covered there).

actor FakeAudioCapture: AudioCapturing {
    nonisolated let metrics: AsyncThrowingStream<CaptureMetrics, Error>
    nonisolated let speechAudio: AsyncStream<SpeechAudioChunk>
    private nonisolated let metricsContinuation: AsyncThrowingStream<CaptureMetrics, Error>.Continuation
    private nonisolated let speechContinuation: AsyncStream<SpeechAudioChunk>.Continuation

    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var startedURL: URL?

    init() {
        let m = AsyncThrowingStream<CaptureMetrics, Error>.makeStream()
        metrics = m.stream
        metricsContinuation = m.continuation
        let s = AsyncStream<SpeechAudioChunk>.makeStream()
        speechAudio = s.stream
        speechContinuation = s.continuation
    }

    /// Writes one second of silence — enough for `AudioFileWriter.frameCount(at:)`
    /// to pass the integrity check in `runFinalizationPipeline`. Content
    /// doesn't matter: `FakeTranscriber`/`FakeDiarizer` never read the file.
    func start(writingTo url: URL) async throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let writer = try AudioFileWriter(url: url, format: format)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        try writer.write(buffer)
        writer.close()
        startedURL = url
        metricsContinuation.yield(CaptureMetrics(elapsed: 1, level: 0.2, peak: 0.3, waveform: [0.2]))
    }

    func pause() async { pauseCount += 1 }
    func resume() async throws { resumeCount += 1 }

    func stop() async -> CaptureResult? {
        metricsContinuation.finish()
        speechContinuation.finish()
        guard let startedURL else { return nil }
        return CaptureResult(url: startedURL, duration: 1, frameCount: 16_000, sampleRate: 16_000)
    }
}

actor FakeTranscriber: SpeechTranscribing {
    private(set) var prepareCalled = false
    private(set) var transcribeFileCalled = false
    var segmentsToReturn: [(TimeInterval, TimeInterval, String)] = [
        (0, 2, "Let's start the sync."),
        (2, 4, "Sounds good to me."),
    ]

    func prepare(model: SpeechModelConfiguration) async throws { prepareCalled = true }
    func startStreaming() async throws {}
    nonisolated func accept(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) async throws {}

    nonisolated func updates() -> AsyncThrowingStream<TranscriptionUpdate, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func finishStreaming() async throws -> FinalTranscription {
        FinalTranscription(segments: [], modelName: "fake")
    }

    func transcribeFile(at url: URL) async throws -> FinalTranscription {
        transcribeFileCalled = true
        let placeholder = UUID()
        return FinalTranscription(
            segments: segmentsToReturn.map { start, end, text in
                TranscriptSegment(
                    recordingID: placeholder, startTime: start, endTime: end, text: text,
                    isFinal: true, source: .final)
            },
            modelName: "fake-model")
    }
}

actor FakeDiarizer: SpeakerDiarizing {
    private(set) var diarizeFileCalled = false
    private(set) var startStreamingCalled = false
    var turnsToReturn: [SpeakerTurn] = [SpeakerTurn(diarizerLabel: "1", startTime: 0, endTime: 4)]

    func prepare() async throws {}
    func startStreaming() async throws { startStreamingCalled = true }
    nonisolated func accept(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) async throws {}

    nonisolated func updates() -> AsyncThrowingStream<DiarizationUpdate, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func finishStreaming() async throws -> DiarizationResult { DiarizationResult(turns: []) }

    func diarizeFile(at url: URL) async throws -> DiarizationResult {
        diarizeFileCalled = true
        return DiarizationResult(turns: turnsToReturn)
    }
}

// MARK: - LM Studio stub wiring
//
// `StubURLProtocol`/`StubRegistry`/`Stub`/`StubOutcome`/`Fixture.completion` are
// declared (non-privately) in LMStudioTests.swift and shared across this
// target rather than redefined.

private func makeStubbedLMStudio(organizedJSON: String) -> LMStudioClient {
    let port = StubRegistry.shared.register(
        Stub(completions: [.reply(status: 200, body: Fixture.completion(organizedJSON))]))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return LMStudioClient(
        configuration: LMStudioConfiguration(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!, modelID: "test-model"),
        session: URLSession(configuration: configuration))
}

/// Deliberately minimal: `LMStudioClient.normalize` fills in every omitted
/// `id`, which `LMStudioTests.swift` already covers exhaustively — this
/// suite only needs enough of a valid reply to prove the coordinator
/// persists what comes back.
private let minimalOrganizedJSON = """
    {
      "title": "Team Sync",
      "shortSummary": "Quick sync about launch prep.",
      "detailedSummary": "",
      "organizedSections": [],
      "keyTakeaways": [],
      "decisions": [],
      "actionItems": [],
      "openQuestions": [],
      "followUps": [],
      "quotes": [],
      "topics": [],
      "tags": ["launch"],
      "speakerSummary": []
    }
    """

@MainActor
@Suite("Recording coordinator")
struct RecordingCoordinatorTests {

    @Test("A full record-to-complete lifecycle persists segments, speakers, and organized notes")
    func fullLifecycle() async throws {
        let repository = RecordingRepository(dbManager: try DatabaseManager.openInMemory())
        let capture = FakeAudioCapture()
        let transcriber = FakeTranscriber()
        let diarizer = FakeDiarizer()
        let coordinator = RecordingCoordinator(
            transcriber: transcriber, diarizer: diarizer,
            lmStudio: makeStubbedLMStudio(organizedJSON: minimalOrganizedJSON),
            repository: repository, makeAudioCapture: { capture })

        try await coordinator.prepareModels(speechModel: SpeechModelConfiguration(modelName: "fake"))
        #expect(coordinator.state == .ready)

        try await coordinator.startRecording()
        #expect(coordinator.state == .recording)
        let recordingID = try #require(coordinator.currentRecording?.id)
        defer { cleanUpTestAudio(for: recordingID) }

        await coordinator.stopRecording()

        #expect(coordinator.state == .complete)
        #expect(await transcriber.transcribeFileCalled)
        #expect(await diarizer.diarizeFileCalled)

        let saved = try #require(try await repository.fetch(id: recordingID))
        #expect(saved.status == .complete)
        #expect(saved.title == "Team Sync")
        #expect(saved.errorStage == nil)

        let segments = try await repository.fetchSegments(recordingID: recordingID)
        #expect(segments.map(\.text) == ["Let's start the sync.", "Sounds good to me."])
        #expect(segments.allSatisfy { $0.recordingID == recordingID })

        let speakers = try await repository.fetchSpeakers(recordingID: recordingID)
        #expect(speakers.map(\.diarizerLabel) == ["1"])
        #expect(!segments.contains { $0.speakerID == nil })

        let organized = try #require(try await repository.fetchOrganizedResult(recordingID: recordingID))
        #expect(organized.title == "Team Sync")
        #expect(organized.tags == ["launch"])
    }

    @Test("Disabling live diarization skips streaming but not the final file-based pass")
    func liveDiarizationToggleGatesOnlyStreaming() async throws {
        let repository = RecordingRepository(dbManager: try DatabaseManager.openInMemory())
        let capture = FakeAudioCapture()
        let diarizer = FakeDiarizer()
        let coordinator = RecordingCoordinator(
            transcriber: FakeTranscriber(), diarizer: diarizer,
            lmStudio: makeStubbedLMStudio(organizedJSON: minimalOrganizedJSON),
            repository: repository, makeAudioCapture: { capture })

        try await coordinator.prepareModels(
            speechModel: SpeechModelConfiguration(modelName: "fake"), liveDiarizationEnabled: false)
        try await coordinator.startRecording()
        let recordingID = try #require(coordinator.currentRecording?.id)
        defer { cleanUpTestAudio(for: recordingID) }
        #expect(await diarizer.startStreamingCalled == false)

        await coordinator.stopRecording()
        #expect(await diarizer.diarizeFileCalled, "the final pass must still run regardless of the live toggle")
    }

    @Test("Pause and resume forward to the capture session and update state")
    func pauseResume() async throws {
        let repository = RecordingRepository(dbManager: try DatabaseManager.openInMemory())
        let capture = FakeAudioCapture()
        let coordinator = RecordingCoordinator(
            transcriber: FakeTranscriber(), diarizer: FakeDiarizer(),
            lmStudio: makeStubbedLMStudio(organizedJSON: minimalOrganizedJSON),
            repository: repository, makeAudioCapture: { capture })

        try await coordinator.prepareModels(speechModel: SpeechModelConfiguration(modelName: "fake"))
        try await coordinator.startRecording()
        let recordingID = try #require(coordinator.currentRecording?.id)
        defer { cleanUpTestAudio(for: recordingID) }

        await coordinator.pauseRecording()
        #expect(coordinator.state == .paused)
        #expect(await capture.pauseCount == 1)

        try await coordinator.resumeRecording()
        #expect(coordinator.state == .recording)
        #expect(await capture.resumeCount == 1)

        await coordinator.stopRecording()
        #expect(coordinator.state == .complete)
    }

    @Test("A note-generation failure still completes the recording, preserving the transcript")
    func organizationFailureDoesNotLoseTheTranscript() async throws {
        let repository = RecordingRepository(dbManager: try DatabaseManager.openInMemory())
        let capture = FakeAudioCapture()
        let port = StubRegistry.shared.register(
            Stub(completions: [.failure(.refused)]))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let lmStudio = LMStudioClient(
            configuration: LMStudioConfiguration(
                baseURL: URL(string: "http://127.0.0.1:\(port)")!, modelID: "test-model"),
            session: URLSession(configuration: configuration))
        let coordinator = RecordingCoordinator(
            transcriber: FakeTranscriber(), diarizer: FakeDiarizer(), lmStudio: lmStudio,
            repository: repository, makeAudioCapture: { capture })

        try await coordinator.prepareModels(speechModel: SpeechModelConfiguration(modelName: "fake"))
        try await coordinator.startRecording()
        let recordingID = try #require(coordinator.currentRecording?.id)
        defer { cleanUpTestAudio(for: recordingID) }

        await coordinator.stopRecording()

        // Plan §5.3: never discard a transcript because note generation
        // failed — the recording still reaches .complete.
        #expect(coordinator.state == .complete)
        let saved = try #require(try await repository.fetch(id: recordingID))
        #expect(saved.status == .complete)
        #expect(saved.errorStage == "organizingFinal")
        #expect(saved.errorMessage != nil)

        let segments = try await repository.fetchSegments(recordingID: recordingID)
        #expect(segments.count == 2)
    }

    @Test("retryOrganization(for:) succeeds on a recording the coordinator never processed")
    func retryOrganizationOnArbitraryRecording() async throws {
        let repository = RecordingRepository(dbManager: try DatabaseManager.openInMemory())
        var recording = Recording(title: "Old Meeting", status: .complete)
        recording.errorStage = "organizingFinal"
        try await repository.save(recording)
        let segment = TranscriptSegment(
            recordingID: recording.id, startTime: 0, endTime: 2, text: "Some prior transcript.",
            isFinal: true, source: .final)
        try await repository.replaceSegments([segment], recordingID: recording.id)

        let coordinator = RecordingCoordinator(
            transcriber: FakeTranscriber(), diarizer: FakeDiarizer(),
            lmStudio: makeStubbedLMStudio(organizedJSON: minimalOrganizedJSON),
            repository: repository, makeAudioCapture: { FakeAudioCapture() })

        // No prepareModels, no startRecording — this coordinator never
        // touched this recording before, exactly the library-retry scenario.
        try await coordinator.retryOrganization(for: recording)

        #expect(coordinator.state == .complete)
        let saved = try #require(try await repository.fetch(id: recording.id))
        #expect(saved.title == "Team Sync")
        #expect(saved.errorStage == nil)
    }

    @Test("recoverAndProcess resumes an interrupted recording from its audio file on disk")
    func recoverAndProcessResumesFromDisk() async throws {
        let repository = RecordingRepository(dbManager: try DatabaseManager.openInMemory())
        var recording = Recording(title: "Interrupted Sync", status: .finalTranscription)
        // The real AppPaths.audioDirectory(for:), not an override of the
        // shared AppPaths.baseDirectory global — this exercises the actual
        // path resolution recoverAndProcess uses, without any risk of racing
        // a concurrently-running test that reads the un-overridden default.
        let audioDirectory = try AppPaths.audioDirectory(for: recording.id)
        let workingURL = audioDirectory.appending(path: "capture.caf")
        defer { try? FileManager.default.removeItem(at: audioDirectory) }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let writer = try AudioFileWriter(url: workingURL, format: format)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        try writer.write(buffer)
        writer.close()
        recording.workingAudioRelativePath = AppPaths.relativePath(of: workingURL)
        try await repository.save(recording)

        let coordinator = RecordingCoordinator(
            transcriber: FakeTranscriber(), diarizer: FakeDiarizer(),
            lmStudio: makeStubbedLMStudio(organizedJSON: minimalOrganizedJSON),
            repository: repository, makeAudioCapture: { FakeAudioCapture() })

        try await coordinator.recoverAndProcess(recording)

        #expect(coordinator.state == .complete)
        let saved = try #require(try await repository.fetch(id: recording.id))
        #expect(saved.status == .complete)
        let segments = try await repository.fetchSegments(recordingID: recording.id)
        #expect(segments.count == 2)
    }

    @Test("keepAudioOnly completes a recording without generating a transcript or notes")
    func keepAudioOnlyCompletesWithoutProcessing() async throws {
        let repository = RecordingRepository(dbManager: try DatabaseManager.openInMemory())
        let recording = Recording(title: "Interrupted", status: .recording)
        try await repository.save(recording)

        let coordinator = RecordingCoordinator(
            transcriber: FakeTranscriber(), diarizer: FakeDiarizer(),
            lmStudio: makeStubbedLMStudio(organizedJSON: minimalOrganizedJSON),
            repository: repository, makeAudioCapture: { FakeAudioCapture() })

        try await coordinator.keepAudioOnly(recording)

        #expect(coordinator.state == .complete)
        let saved = try #require(try await repository.fetch(id: recording.id))
        #expect(saved.status == .complete)
        #expect(try await repository.fetchOrganizedResult(recordingID: recording.id) == nil)
        #expect(try await repository.fetchSegments(recordingID: recording.id).isEmpty)
    }
}

@MainActor
@Suite("Recovery service")
struct RecoveryServiceTests {

    @Test("Finds interrupted recordings and deletes both their row and their audio")
    func detectAndDelete() async throws {
        let repository = RecordingRepository(dbManager: try DatabaseManager.openInMemory())
        let recoveryService = RecoveryService(repository: repository)

        var recording = Recording(title: "Interrupted", status: .recording)
        let audioDirectory = try AppPaths.audioDirectory(for: recording.id)
        let workingURL = audioDirectory.appending(path: "capture.caf")
        defer { try? FileManager.default.removeItem(at: audioDirectory) }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        try AudioFileWriter(url: workingURL, format: format).close()
        recording.workingAudioRelativePath = AppPaths.relativePath(of: workingURL)
        try await repository.save(recording)

        let interrupted = try await recoveryService.detectInterrupted()
        #expect(interrupted.map(\.id) == [recording.id])
        #expect(FileManager.default.fileExists(atPath: workingURL.path))

        try await recoveryService.deletePermanently(recording)

        #expect(try await repository.fetch(id: recording.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: audioDirectory.path))
    }
}
