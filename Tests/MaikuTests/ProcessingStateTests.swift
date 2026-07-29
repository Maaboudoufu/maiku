import Foundation
import Testing

@testable import MaikuKit

@Suite("Recording state machine")
struct ProcessingStateTests {

    @Test("Happy path walks idle → complete")
    func happyPath() {
        let path: [RecordingState] = [
            .idle, .requestingPermission, .preparingModels, .ready, .recording, .stopping,
            .processing(.finalizingAudio), .processing(.finalTranscription),
            .processing(.finalDiarization), .processing(.organizingChunks),
            .processing(.organizingFinal), .complete,
        ]
        for (from, to) in zip(path, path.dropFirst()) {
            #expect(from.canTransition(to: to), "\(from) → \(to) should be legal")
        }
    }

    @Test("Pause and resume round-trips")
    func pauseResume() {
        #expect(RecordingState.recording.canTransition(to: .paused))
        #expect(RecordingState.paused.canTransition(to: .recording))
        #expect(RecordingState.paused.canTransition(to: .stopping))
    }

    @Test("Processing stages cannot be skipped")
    func noStageSkipping() {
        #expect(
            !RecordingState.processing(.finalizingAudio)
                .canTransition(to: .processing(.finalDiarization)))
        #expect(
            !RecordingState.processing(.finalTranscription)
                .canTransition(to: .processing(.finalizingAudio)),
            "stages must not run backwards")
    }

    @Test("A stage may re-run itself on retry")
    func stageRetry() {
        for stage in ProcessingStage.allCases {
            #expect(RecordingState.processing(stage).canTransition(to: .processing(stage)))
        }
    }

    @Test("Recording cannot jump straight to complete")
    func noShortcutToComplete() {
        #expect(!RecordingState.recording.canTransition(to: .complete))
        #expect(!RecordingState.ready.canTransition(to: .processing(.organizingFinal)))
    }

    @Test("Any processing stage may fail, and failure is recoverable")
    func failureIsRecoverable() {
        for stage in ProcessingStage.allCases {
            let s = RecordingState.processing(stage)
            #expect(s.canTransition(to: .failed(stage: stage.rawValue, message: "boom")))
        }
        let failed = RecordingState.failed(stage: "finalDiarization", message: "boom")
        #expect(failed.canTransition(to: .processing(.finalDiarization)))
        #expect(failed.canTransition(to: .idle))
    }

    @Test("Organization can be retried without retranscribing")
    func retryOrganizationOnly() {
        #expect(RecordingState.complete.canTransition(to: .processing(.organizingChunks)))
        #expect(
            !RecordingState.complete.canTransition(to: .processing(.finalTranscription)),
            "retrying notes must not re-run transcription")
    }

    @Test("Microphone-live states are exactly the capturing ones")
    func capturingStates() {
        #expect(RecordingState.recording.isCapturingAudio)
        #expect(RecordingState.paused.isCapturingAudio)
        #expect(RecordingState.stopping.isCapturingAudio)
        #expect(!RecordingState.ready.isCapturingAudio)
        #expect(!RecordingState.processing(.finalizingAudio).isCapturingAudio)
        #expect(!RecordingState.complete.isCapturingAudio)
    }
}

@Suite("Error presentation")
struct MaikuErrorTests {

    @Test("Every error carries a message and at least one action, except not-found")
    func everyErrorIsActionable() {
        let errors: [MaikuError] = [
            .microphonePermissionDenied, .noMicrophoneFound, .microphoneDisconnected,
            .audioEngineFailed("x"), .audioFileWriteFailed("x"), .lowDiskSpace(availableBytes: 1024),
            .speechModelMissing(name: "tiny.en"),
            .speechModelLoadFailed(name: "tiny.en", underlying: "x"),
            .transcriptionFailed("x"), .diarizationFailed("x"),
            .lmStudioUnreachable(baseURL: "http://127.0.0.1:1234"), .lmStudioNoModelAvailable,
            .lmStudioTimedOut(seconds: 30), .lmStudioContextTooLarge(tokens: 9000),
            .lmStudioInvalidStructuredOutput(detail: "x"),
            .lmStudioHTTPError(status: 500, body: "x"),
            .databaseFailure("x"), .fileIntegrityCheckFailed(path: "/tmp/x"),
        ]
        for e in errors {
            #expect(!e.message.isEmpty, "\(e) needs a message")
            #expect(!e.recoveryActions.isEmpty, "\(e) needs a recovery action")
        }
    }

    @Test("LM Studio failure modes stay distinguishable")
    func lmStudioCasesAreDistinct() {
        let cases: [MaikuError] = [
            .lmStudioUnreachable(baseURL: "http://127.0.0.1:1234"),
            .lmStudioNoModelAvailable,
            .lmStudioTimedOut(seconds: 30),
            .lmStudioContextTooLarge(tokens: nil),
            .lmStudioInvalidStructuredOutput(detail: "bad json"),
        ]
        #expect(Set(cases.map(\.message)).count == cases.count)
    }
}
