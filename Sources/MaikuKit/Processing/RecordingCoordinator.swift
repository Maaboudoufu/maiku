import Foundation
import Observation

/// Drives one recording from "ready" through to "complete", owning the
/// `RecordingState` machine declared in `ProcessingState.swift` and wiring
/// together audio capture, the speech adapters, diarization alignment,
/// persistence, and LM Studio — the whole vertical slice plan §16 Milestone 1
/// asks for. `@MainActor` because every property here drives SwiftUI directly;
/// the actors it calls into (`AudioCaptureService`, `WhisperKitTranscriber`,
/// `FluidAudioDiarizer`, `LMStudioClient`) do their own off-main work.
@MainActor
@Observable
public final class RecordingCoordinator {

    public private(set) var state: RecordingState = .idle
    public private(set) var currentRecording: Recording?
    public private(set) var metrics = CaptureMetrics(elapsed: 0, level: 0, peak: 0, waveform: [])
    public private(set) var liveSegments: [TranscriptSegment] = []
    public private(set) var liveUnstableText: String = ""
    /// Provisional "who spoke when" (plan §6.4). Purely a live-UI concern —
    /// never persisted as `Speaker` rows, since the file-based pass after
    /// stop is canonical and replaces this outright. Pair with
    /// `liveSegments` through `SpeakerAlignmentService.labels(for:turns:)`
    /// to badge the live transcript.
    public private(set) var liveSpeakerTurns: [SpeakerTurn] = []
    public private(set) var lastError: MaikuError?

    private let transcriber: any SpeechTranscribing
    private let diarizer: any SpeakerDiarizing
    private let lmStudio: LMStudioClient
    private let organizationPipeline: OrganizationPipeline
    private let repository: RecordingRepository
    private let makeAudioCapture: @Sendable () -> any AudioCapturing

    private var audioCapture: (any AudioCapturing)?
    private var speechModel: SpeechModelConfiguration?
    private var streamingTasks: [Task<Void, Never>] = []
    /// Plan §10.7's "Live diarization toggle" and §18's degrade-gracefully
    /// order ("disabling live diarization before dropping audio or live
    /// transcription"): gates only the streaming speaker labels, never the
    /// file-based final pass after stop, which stays on regardless.
    private var liveDiarizationEnabled = true

    /// - Parameter makeAudioCapture: builds a fresh capture session for each
    ///   recording — `AudioCaptureService`'s streams finish when it stops and
    ///   cannot be restarted, so one instance per recording is required
    ///   either way. Overridable so tests can exercise the full lifecycle
    ///   without a real microphone.
    public init(
        transcriber: any SpeechTranscribing, diarizer: any SpeakerDiarizing,
        lmStudio: LMStudioClient, repository: RecordingRepository,
        makeAudioCapture: @escaping @Sendable () -> any AudioCapturing = { AudioCaptureService() }
    ) {
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.lmStudio = lmStudio
        self.organizationPipeline = OrganizationPipeline(lmStudio: lmStudio)
        self.repository = repository
        self.makeAudioCapture = makeAudioCapture
    }

    // MARK: - Setup

    public func prepareModels(
        speechModel: SpeechModelConfiguration, liveDiarizationEnabled: Bool = true
    ) async throws {
        state = .preparingModels
        do {
            try await transcriber.prepare(model: speechModel)
            try await diarizer.prepare()
        } catch {
            let wrapped =
                (error as? MaikuError)
                ?? .speechModelLoadFailed(name: speechModel.modelName, underlying: "\(error)")
            fail(wrapped, stage: "preparingModels")
            throw wrapped
        }
        self.speechModel = speechModel
        self.liveDiarizationEnabled = liveDiarizationEnabled
        state = .ready
    }

    // MARK: - Recording

    public func startRecording() async throws {
        guard audioCapture == nil else {
            throw MaikuError.audioEngineFailed("A recording is already in progress.")
        }

        var recording = Recording(
            title: Self.defaultTitle(), status: .recording, recordingStartedAt: Date())
        recording.transcriptionModel = speechModel?.modelName

        let workingURL: URL
        do {
            workingURL = try AppPaths.audioDirectory(for: recording.id)
                .appending(path: "capture.caf")
            recording.workingAudioRelativePath = AppPaths.relativePath(of: workingURL)
        } catch {
            let wrapped = MaikuError.audioFileWriteFailed("\(error)")
            fail(wrapped, stage: "recording")
            throw wrapped
        }

        do {
            try await repository.save(recording)
        } catch {
            let wrapped = (error as? MaikuError) ?? .databaseFailure("\(error)")
            fail(wrapped, stage: "recording")
            throw wrapped
        }

        let capture = makeAudioCapture()
        do {
            try await capture.start(writingTo: workingURL)
        } catch {
            let wrapped = (error as? MaikuError) ?? .audioEngineFailed("\(error)")
            fail(wrapped, stage: "recording")
            throw wrapped
        }

        try await transcriber.startStreaming()
        if liveDiarizationEnabled {
            try await diarizer.startStreaming()
        }

        audioCapture = capture
        currentRecording = recording
        liveSegments = []
        liveUnstableText = ""
        liveSpeakerTurns = []
        lastError = nil
        state = .recording
        launchStreamingTasks(capture: capture, recordingID: recording.id)
        Task { await DiagnosticLog.shared.log("[\(recording.id)] recording started") }
    }

    public func pauseRecording() async {
        guard let capture = audioCapture, state == .recording else { return }
        await capture.pause()
        state = .paused
    }

    public func resumeRecording() async throws {
        guard let capture = audioCapture, state == .paused else { return }
        do {
            try await capture.resume()
        } catch {
            throw (error as? MaikuError) ?? .audioEngineFailed("\(error)")
        }
        state = .recording
    }

    public func stopRecording() async {
        guard let capture = audioCapture, var recording = currentRecording else { return }
        state = .stopping
        streamingTasks.forEach { $0.cancel() }
        streamingTasks = []

        let captureResult = await capture.stop()
        audioCapture = nil

        recording.recordingEndedAt = Date()
        if let captureResult {
            recording.durationSeconds = captureResult.duration
            recording.workingAudioRelativePath = AppPaths.relativePath(of: captureResult.url)
        }
        currentRecording = recording

        await runFinalizationPipeline(workingAudioURL: captureResult?.url, recording: recording)
    }

    /// Plan §9's "Recover and process", for a recording found interrupted at
    /// launch (`RecordingRepository.fetchInterrupted()`) — and equally usable
    /// as a general "retry processing" action on any recording stuck in
    /// `.failed`, since both are the same problem: audio is safely on disk,
    /// but the pipeline never reached `.complete`.
    ///
    /// ponytail: always restarts at `finalizingAudio` rather than resuming
    /// from the exact stage it was interrupted at (skipping transcription if
    /// segments already exist, etc.). Every stage already replaces its own
    /// output wholesale, so this is correct either way — just capable of
    /// redoing work a smarter resume would skip. Upgrade if reprocessing a
    /// long recording's transcription on every retry becomes a real cost.
    public func recoverAndProcess(_ recording: Recording) async throws {
        guard let relativePath = recording.workingAudioRelativePath ?? recording.audioRelativePath,
            let url = AppPaths.absoluteURL(forRelativePath: relativePath)
        else {
            let error = MaikuError.fileIntegrityCheckFailed(
                path: recording.workingAudioRelativePath ?? recording.audioRelativePath ?? "")
            fail(error, stage: "finalizingAudio")
            throw error
        }
        currentRecording = recording
        await runFinalizationPipeline(workingAudioURL: url, recording: recording)
        if case .failed(_, let message) = state {
            throw lastError ?? .databaseFailure(message)
        }
    }

    /// Plan §9's "Keep raw audio only": the user declines further
    /// processing for an interrupted recording. The audio stays exactly
    /// where it is; the recording is simply marked done with whatever
    /// transcript or notes it already has, which may be none.
    public func keepAudioOnly(_ recording: Recording) async throws {
        var updated = recording
        updated.status = .complete
        updated.errorStage = nil
        updated.errorMessage = nil
        updated.processingProgress = nil
        updated.updatedAt = Date()
        do {
            try await repository.save(updated)
        } catch {
            let wrapped = (error as? MaikuError) ?? .databaseFailure("\(error)")
            fail(wrapped, stage: "finalizingAudio")
            throw wrapped
        }
        currentRecording = updated
        lastError = nil
        state = .complete
    }

    /// Retries note generation from what is already persisted, without
    /// re-transcribing or re-diarizing (plan §5.3, §7.2). Takes the recording
    /// explicitly rather than reading `currentRecording`, so retrying works
    /// from the library on any past recording, not only the one just made.
    public func retryOrganization(for recording: Recording) async throws {
        currentRecording = recording
        state = .processing(.organizingChunks)
        do {
            let segments = try await repository.fetchSegments(recordingID: recording.id)
            let speakers = try await repository.fetchSpeakers(recordingID: recording.id)
            let organized = try await organizationPipeline.organize(
                recordingID: recording.id, recordedAt: recording.recordingStartedAt,
                durationSeconds: recording.durationSeconds, segments: segments, speakers: speakers)
            state = .processing(.organizingFinal)
            try await repository.saveOrganizedResult(organized, recordingID: recording.id)

            var updated = recording
            if !organized.title.isEmpty { updated.title = organized.title }
            updated.status = .complete
            updated.errorStage = nil
            updated.errorMessage = nil
            updated.lmStudioModel = lmStudio.configuration.modelID
            updated.updatedAt = Date()
            try await repository.save(updated)
            currentRecording = updated
            lastError = nil
            state = .complete
        } catch {
            let wrapped = (error as? MaikuError) ?? .databaseFailure("\(error)")
            fail(wrapped, stage: "organizingFinal")
            throw wrapped
        }
    }

    // MARK: - Live streaming

    private func launchStreamingTasks(capture: any AudioCapturing, recordingID: UUID) {
        streamingTasks.append(
            Task { [weak self] in
                guard let self else { return }
                do {
                    for try await update in capture.metrics {
                        self.metrics = update
                    }
                } catch let error as MaikuError {
                    self.handleCaptureFailure(error)
                } catch {
                    self.handleCaptureFailure(.audioEngineFailed("\(error)"))
                }
            })

        streamingTasks.append(
            Task { [weak self] in
                guard let self else { return }
                // AsyncStream is single-consumer, so both the transcriber and
                // the diarizer are fed from this one loop rather than each
                // trying to iterate capture.speechAudio independently.
                for await chunk in capture.speechAudio {
                    guard let buffer = chunk.makeBuffer() else { continue }
                    try? await self.transcriber.accept(buffer, at: chunk.startTime)
                    if self.liveDiarizationEnabled {
                        try? await self.diarizer.accept(buffer, at: chunk.startTime)
                    }
                }
            })

        streamingTasks.append(
            Task { [weak self] in
                guard let self else { return }
                do {
                    for try await update in self.transcriber.updates() {
                        guard !Task.isCancelled else { return }
                        var stamped = update.stableSegments
                        for i in stamped.indices { stamped[i].recordingID = recordingID }
                        if !stamped.isEmpty {
                            self.liveSegments.append(contentsOf: stamped)
                            // Database checkpoint as stable segments arrive (plan §6.3).
                            try? await self.repository.replaceSegments(
                                self.liveSegments, recordingID: recordingID)
                        }
                        self.liveUnstableText = update.unstableText
                    }
                } catch {
                    // Live transcription is provisional; losing the stream does
                    // not end the recording (plan §6.4's allowance applies here
                    // just as much as to diarization).
                }
            })

        if liveDiarizationEnabled {
            streamingTasks.append(
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        for try await update in self.diarizer.updates() {
                            guard !Task.isCancelled else { return }
                            self.liveSpeakerTurns = update.turns
                        }
                    } catch {
                        // Provisional speaker labels are exactly that — plan §6.4
                        // explicitly allows losing live diarization without
                        // ending the recording, same as losing live transcription.
                    }
                })
        }
    }

    private func handleCaptureFailure(_ error: MaikuError) {
        guard audioCapture != nil else { return }
        audioCapture = nil
        streamingTasks.forEach { $0.cancel() }
        streamingTasks = []
        fail(error, stage: "recording")
    }

    // MARK: - Finalization

    private func runFinalizationPipeline(workingAudioURL: URL?, recording initial: Recording) async {
        var recording = initial
        do {
            state = .processing(.finalizingAudio)
            guard let workingAudioURL else {
                throw MaikuError.audioFileWriteFailed("No audio was captured.")
            }
            _ = try AudioFileWriter.frameCount(at: workingAudioURL)
            recording.status = .finalizingAudio
            recording.updatedAt = Date()
            try await save(recording)

            state = .processing(.finalTranscription)
            recording.status = .finalTranscription
            try await save(recording)
            let finalTranscription = try await transcriber.transcribeFile(at: workingAudioURL)
            var segments = finalTranscription.segments
            for i in segments.indices { segments[i].recordingID = recording.id }
            recording.transcriptionModel = finalTranscription.modelName
            if let language = finalTranscription.detectedLanguage { recording.language = language }

            state = .processing(.finalDiarization)
            recording.status = .finalDiarization
            try await save(recording)
            let diarization = try await diarizer.diarizeFile(at: workingAudioURL)
            let (speakers, speakerIDs) = Self.makeSpeakers(for: diarization, recordingID: recording.id)
            if !speakers.isEmpty {
                try await repository.upsertSpeakers(speakers, recordingID: recording.id)
            }
            segments = SpeakerAlignmentService.align(segments, to: diarization.turns, speakerIDs: speakerIDs)
            try await repository.replaceSegments(segments, recordingID: recording.id)

            state = .processing(.organizingChunks)
            recording.status = .organizingChunks
            try await save(recording)
            do {
                let organized = try await organizationPipeline.organize(
                    recordingID: recording.id, recordedAt: recording.recordingStartedAt,
                    durationSeconds: recording.durationSeconds, segments: segments, speakers: speakers)
                state = .processing(.organizingFinal)
                recording.status = .organizingFinal
                recording.lmStudioModel = lmStudio.configuration.modelID
                try await save(recording)
                if !organized.title.isEmpty { recording.title = organized.title }
                try await repository.saveOrganizedResult(organized, recordingID: recording.id)
                recording.errorStage = nil
                recording.errorMessage = nil
            } catch {
                // Plan §5.3: never discard a transcript because note
                // generation failed. The recording still completes; the
                // failure is recorded so the UI can offer a retry.
                let noteError = (error as? MaikuError) ?? .databaseFailure("\(error)")
                recording.errorStage = "organizingFinal"
                recording.errorMessage = noteError.message
            }

            recording.status = .complete
            recording.processingProgress = nil
            recording.updatedAt = Date()
            try await save(recording)
            currentRecording = recording
            state = .complete
            Task { await DiagnosticLog.shared.log("[\(recording.id)] processing complete") }
        } catch {
            let wrapped = (error as? MaikuError) ?? .databaseFailure("\(error)")
            recording.status = .failed
            recording.errorMessage = wrapped.message
            try? await repository.save(recording)
            currentRecording = recording
            let stageName: String
            if case .processing(let stage) = state { stageName = stage.rawValue } else { stageName = "finalization" }
            fail(wrapped, stage: stageName)
        }
    }

    private func save(_ recording: Recording) async throws {
        try await repository.save(recording)
    }

    private func fail(_ error: MaikuError, stage: String) {
        lastError = error
        state = .failed(stage: stage, message: error.message)
        let recordingID = currentRecording?.id.uuidString ?? "unknown"
        Task { await DiagnosticLog.shared.log("[\(recordingID)] failed at \(stage): \(error.message)", level: .error) }
    }

    private static func makeSpeakers(
        for diarization: DiarizationResult, recordingID: UUID
    ) -> (speakers: [Speaker], speakerIDs: [String: UUID]) {
        var speakerIDs: [String: UUID] = [:]
        var speakers: [Speaker] = []
        for (index, label) in diarization.speakerLabels.enumerated() {
            let speaker = Speaker(recordingID: recordingID, diarizerLabel: label, colorIndex: index)
            speakerIDs[label] = speaker.id
            speakers.append(speaker)
        }
        return (speakers, speakerIDs)
    }

    private static func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Recording — \(formatter.string(from: Date()))"
    }
}
