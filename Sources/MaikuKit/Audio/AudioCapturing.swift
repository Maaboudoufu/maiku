import AVFoundation
import Foundation

/// What `RecordingCoordinator` needs from microphone capture, abstracted the
/// same way `SpeechTranscribing`/`SpeakerDiarizing` already abstract the
/// speech stack — so the full record-to-complete lifecycle is testable
/// without a real microphone (plan §17.2), not just the pieces on either
/// side of it.
public protocol AudioCapturing: Sendable {
    var metrics: AsyncThrowingStream<CaptureMetrics, Error> { get }
    var speechAudio: AsyncStream<SpeechAudioChunk> { get }
    func start(writingTo url: URL) async throws
    func pause() async
    func resume() async throws
    @discardableResult func stop() async -> CaptureResult?
}

extension AudioCaptureService: AudioCapturing {}
