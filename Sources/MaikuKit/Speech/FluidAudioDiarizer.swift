import AVFoundation
import FluidAudio
import Foundation

/// FluidAudio behind `SpeakerDiarizing` (plan §5.2, §6.4).
///
/// `FluidAudio.DiarizationResult` is a distinct type from this module's own
/// `DiarizationResult` (declared in `SpeechProtocols.swift`) — every use below
/// is qualified with `FluidAudio.` to keep that unambiguous.
public actor FluidAudioDiarizer: SpeakerDiarizing {

    /// How much *new* audio to accumulate before re-running diarization over
    /// the window. Longer than `WhisperKitTranscriber`'s 3 s: embedding
    /// extraction and clustering cost more per call than a transcription
    /// pass, and provisional speaker labels are inherently coarser-grained
    /// than provisional text.
    private static let flushInterval: TimeInterval = 6

    /// Hard ceiling on retained audio (plan §6.2, §18) — the same bound
    /// `WhisperKitTranscriber` enforces on its own rolling window, for the
    /// same reason: a two-hour recording must not grow this without bound.
    private static let maxWindowDuration: TimeInterval = 30
    private static let overlap: TimeInterval = 2

    private var manager: DiarizerManager?

    // Streaming state
    private var windowSamples: [Float] = []
    private var windowStartTime: TimeInterval = 0
    private var newSamplesSinceFlush: Int = 0
    private var emittedTurns: [SpeakerTurn] = []
    private var continuation: AsyncThrowingStream<DiarizationUpdate, Error>.Continuation?

    /// `nonisolated(unsafe)`: see the identical property on
    /// `WhisperKitTranscriber` — `updates()` must be `nonisolated` to satisfy
    /// the protocol's synchronous signature, yet the stream has to be
    /// recreated every `startStreaming()`. Safe under the same invariant:
    /// `await startStreaming()` completes before `updates()` is read for
    /// that recording.
    nonisolated(unsafe) private var updateStream = AsyncThrowingStream<DiarizationUpdate, Error> { $0.finish() }

    public init() {}

    public func prepare() async throws {
        guard manager == nil else { return }
        do {
            let models = try await DiarizerModels.downloadIfNeeded()
            let manager = DiarizerManager()
            manager.initialize(models: models)
            self.manager = manager
        } catch {
            throw MaikuError.diarizationFailed(error.localizedDescription)
        }
    }

    // MARK: Streaming
    //
    // Reuses `DiarizerManager.performCompleteDiarization` — the same offline
    // pipeline `diarizeFile(at:)` already calls — on a bounded, periodically
    // re-diarized rolling window, rather than adopting FluidAudio's separate
    // `Diarizer` streaming protocol (Sortformer/LS-EEND). Those are different
    // models entirely: a second download, a different API, and a live
    // speaker numbering with no guaranteed relationship to the file-based
    // pass's numbering for the *same* recording. Reusing the identical
    // pipeline the final pass uses means "Speaker 1" during recording and
    // "Speaker 1" in the final result are, in practice, the same voice far
    // more often than two unrelated models would agree — and there is no
    // new dependency to integrate. `DiarizerManager.speakerManager` persists
    // across calls on the same instance, so periodic flushes on a trimmed
    // window still cluster against everyone recognised earlier in the
    // session, rather than restarting cold each time.

    public func startStreaming() async throws {
        windowSamples = []
        windowStartTime = 0
        newSamplesSinceFlush = 0
        emittedTurns = []
        // A fresh session must never inherit speaker state from a previous
        // recording processed by this same long-lived actor instance, or
        // from this same recording's own prior attempt.
        manager?.speakerManager = SpeakerManager()

        var newContinuation: AsyncThrowingStream<DiarizationUpdate, Error>.Continuation!
        updateStream = AsyncThrowingStream { newContinuation = $0 }
        continuation = newContinuation
    }

    /// `nonisolated`, matching `WhisperKitTranscriber.accept`: `AVAudioPCMBuffer`
    /// is not `Sendable`, so no actor's `accept` can accept it while isolated.
    /// Samples are copied out into a plain `[Float]` here, before any actor hop.
    public nonisolated func accept(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) async throws {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        try await ingest(samples, sampleRate: Double(buffer.format.sampleRate), at: time)
    }

    private func ingest(_ samples: [Float], sampleRate: Double, at time: TimeInterval) async throws {
        if windowSamples.isEmpty { windowStartTime = time }
        windowSamples.append(contentsOf: samples)
        newSamplesSinceFlush += samples.count

        guard sampleRate > 0, Double(newSamplesSinceFlush) / sampleRate >= Self.flushInterval else { return }
        newSamplesSinceFlush = 0
        try await flush(sampleRate: sampleRate)
    }

    public nonisolated func updates() -> AsyncThrowingStream<DiarizationUpdate, Error> {
        updateStream
    }

    public func finishStreaming() async throws -> DiarizationResult {
        if !windowSamples.isEmpty {
            try await flush(sampleRate: Double(SpeechAudioChunk.format.sampleRate), isFinal: true)
        }
        continuation?.finish()
        return DiarizationResult(turns: emittedTurns)
    }

    private func flush(sampleRate: Double, isFinal: Bool = false) async throws {
        guard let manager else {
            throw MaikuError.diarizationFailed("prepare() was not called.")
        }
        // No explicit type annotation on `result`: this module also declares
        // a type named `DiarizationResult` (in SpeechProtocols.swift), and
        // spelling the bare name here to disambiguate — rather than letting
        // it infer from performCompleteDiarization's return type, as
        // diarizeFile below already does successfully — risks resolving to
        // the wrong one.
        let windowTurns: [SpeakerTurn]
        do {
            let result = try manager.performCompleteDiarization(
                windowSamples, sampleRate: Int(sampleRate), atTime: windowStartTime)
            windowTurns = result.segments.map { segment in
                SpeakerTurn(
                    diarizerLabel: segment.speakerId,
                    startTime: TimeInterval(segment.startTimeSeconds),
                    endTime: TimeInterval(segment.endTimeSeconds),
                    quality: Double(segment.qualityScore))
            }
        } catch {
            throw MaikuError.diarizationFailed(error.localizedDescription)
        }

        emittedTurns = Self.mergeTurns(
            settled: emittedTurns, windowTurns: windowTurns, windowStartTime: windowStartTime)
        continuation?.yield(DiarizationUpdate(turns: emittedTurns))

        guard !isFinal else { return }

        let retainFrom = max(0, Double(windowSamples.count) / sampleRate - Self.overlap)
        let dropSamples = min(windowSamples.count, Int(retainFrom * sampleRate))
        if dropSamples > 0 {
            windowSamples.removeFirst(dropSamples)
            windowStartTime += Double(dropSamples) / sampleRate
        }
        let maxSamples = Int(Self.maxWindowDuration * sampleRate)
        if windowSamples.count > maxSamples {
            let excess = windowSamples.count - maxSamples
            windowSamples.removeFirst(excess)
            windowStartTime += Double(excess) / sampleRate
        }
    }

    // MARK: File-based (canonical)

    public func diarizeFile(at url: URL) async throws -> DiarizationResult {
        guard let manager else {
            throw MaikuError.diarizationFailed("prepare() was not called.")
        }
        // The canonical pass must not be biased by whatever this instance's
        // speakerManager picked up from live streaming (this recording's own
        // provisional pass, or an earlier recording's) — plan §6.4 treats
        // this result as authoritative, and re-discovering every speaker
        // fresh from the complete file is exactly what makes it so.
        manager.speakerManager = SpeakerManager()

        let samples: [Float]
        do {
            samples = try Self.loadMono16k(url)
        } catch {
            throw MaikuError.fileIntegrityCheckFailed(path: url.path)
        }
        do {
            let result = try manager.performCompleteDiarization(samples, sampleRate: 16_000)
            let turns = result.segments.map { segment in
                SpeakerTurn(
                    diarizerLabel: segment.speakerId,
                    startTime: TimeInterval(segment.startTimeSeconds),
                    endTime: TimeInterval(segment.endTimeSeconds),
                    quality: Double(segment.qualityScore))
            }
            return DiarizationResult(turns: turns)
        } catch {
            throw MaikuError.diarizationFailed(error.localizedDescription)
        }
    }

    /// Turns entirely before this window are settled history; turns this
    /// window covers get replaced by the latest, more-informed pass over
    /// that same span (plan §6.3's "timestamp-aware merging" applied to
    /// speaker turns rather than transcript text). Pure and free of
    /// FluidAudio so it is testable without a model, matching how
    /// `WhisperKitTranscriber`'s `StreamingMerge` is kept separately testable.
    static func mergeTurns(
        settled: [SpeakerTurn], windowTurns: [SpeakerTurn], windowStartTime: TimeInterval
    ) -> [SpeakerTurn] {
        settled.filter { $0.endTime <= windowStartTime } + windowTurns
    }

    /// Reads a whole audio file as mono 16 kHz `Float` samples — the format
    /// FluidAudio's diarizer expects. Plain `AVAudioFile` + `AVAudioConverter`,
    /// the same approach verified end-to-end in the Milestone 0 spike;
    /// deliberately independent of WhisperKit's own audio loader so this
    /// adapter has no reason to import it.
    private static func loadMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
            let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat)
        else {
            throw MaikuError.fileIntegrityCheckFailed(path: url.path)
        }
        try file.read(into: sourceBuffer)

        let outCapacity =
            AVAudioFrameCount(Double(file.length) * 16_000.0 / file.processingFormat.sampleRate) + 1_024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            throw MaikuError.fileIntegrityCheckFailed(path: url.path)
        }

        let source = ConverterInput(sourceBuffer)
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if source.isConsumed {
                status.pointee = .noDataNow
                return nil
            }
            source.isConsumed = true
            status.pointee = .haveData
            return source.buffer
        }
        if let conversionError { throw conversionError }
        guard let channel = outputBuffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
    }
}

/// Carries a non-`Sendable` buffer into `AVAudioConverter`'s `@Sendable` input
/// block. Safe because `convert` calls that block synchronously, on this
/// thread, before it returns — the box never outlives the call. Same
/// pattern as `AudioCaptureService.swift`'s `ConverterInput`, duplicated
/// rather than shared because sharing it would mean either file importing
/// the other for one four-line type.
private final class ConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var isConsumed = false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}
