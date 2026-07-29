import AVFoundation
import Foundation

// MARK: - Values crossing out of the capture domain

/// One throttled snapshot of the live input, for the recording screen.
public struct CaptureMetrics: Sendable, Equatable {
    /// Seconds of audio actually captured. Does not advance while paused.
    public let elapsed: TimeInterval
    /// 0…1 on a decibel scale, ready to drive a meter bar.
    public let level: Float
    /// Linear peak magnitude since the previous snapshot; above 1 means clipping.
    public let peak: Float
    /// Recent per-snapshot peaks, oldest first, so the view can draw a scrolling
    /// waveform without keeping history of its own.
    public let waveform: [Float]

    public init(elapsed: TimeInterval, level: Float, peak: Float, waveform: [Float]) {
        self.elapsed = elapsed
        self.level = level
        self.peak = peak
        self.waveform = waveform
    }
}

/// A resampled slice of input for the speech stack.
///
/// Plain `[Float]` rather than `AVAudioPCMBuffer` because this crosses into the
/// transcriber's isolation domain and `AVAudioPCMBuffer` is not `Sendable`. Call
/// `makeBuffer()` on the far side to get one back.
public struct SpeechAudioChunk: Sendable, Equatable {
    public let samples: [Float]
    /// Seconds from the start of the recording, counted in captured frames.
    public let startTime: TimeInterval

    public init(samples: [Float], startTime: TimeInterval) {
        self.samples = samples
        self.startTime = startTime
    }

    /// 16 kHz mono Float32 — what WhisperKit and FluidAudio both want.
    public static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    public func makeBuffer() -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(samples.count)),
            let destination = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            destination[0].update(from: $0.baseAddress!, count: samples.count)
        }
        return buffer
    }
}

/// What a finished (or interrupted) capture left on disk.
public struct CaptureResult: Sendable, Equatable {
    public let url: URL
    public let duration: TimeInterval
    public let frameCount: AVAudioFramePosition
    public let sampleRate: Double
}

// MARK: - Timeline

/// Position in the recording, counted in frames actually captured.
///
/// Deliberately not wall clock. Pause/resume must not open a gap between the
/// audio file's timeline and the transcript's, and dropped buffers should
/// shorten the timeline rather than silently desynchronise everything after
/// them (plan §6.2). Frames written to the file *are* the clock.
struct CaptureClock: Sendable {
    let sampleRate: Double
    private(set) var frames: AVAudioFramePosition = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    var elapsed: TimeInterval { sampleRate > 0 ? Double(frames) / sampleRate : 0 }

    /// Appends `count` frames and returns the time at which they start.
    @discardableResult
    mutating func advance(by count: AVAudioFrameCount) -> TimeInterval {
        let start = elapsed
        frames += AVAudioFramePosition(count)
        return start
    }
}

// MARK: - Resampling

/// Device rate in, 16 kHz mono out.
///
/// Stateful: the converter carries the resampler's tail between calls, which is
/// what stops buffer boundaries from clicking. One instance per recording, and
/// never `reset()` mid-recording.
struct SpeechResampler {
    private let converter: AVAudioConverter

    init?(from input: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: SpeechAudioChunk.format) else {
            return nil
        }
        self.converter = converter
    }

    /// Returns an empty array when the converter is still priming or fails; the
    /// working file is unaffected either way, so the final pass still has
    /// everything.
    func resample(_ input: AVAudioPCMBuffer) -> [Float] {
        guard input.frameLength > 0, input.format.sampleRate > 0 else { return [] }
        let ratio = SpeechAudioChunk.format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: SpeechAudioChunk.format, frameCapacity: capacity)
        else { return [] }

        let source = ConverterInput(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if source.isConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            source.isConsumed = true
            outStatus.pointee = .haveData
            return source.buffer
        }
        guard status != .error, output.frameLength > 0, let channel = output.floatChannelData
        else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}

/// Carries a non-`Sendable` buffer into `AVAudioConverter`'s `@Sendable` input
/// block. Safe because `convert` calls that block synchronously, on this thread,
/// before it returns — the box never outlives the call.
private final class ConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var isConsumed = false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

// MARK: - Render-thread state

/// Everything the audio render thread touches, behind one lock.
///
/// `AudioCaptureService` is an actor, but Core Audio calls the tap on its own
/// real-time thread and will not wait for an actor hop. So the tap's state lives
/// here instead of in the actor, and the actor reaches it only through the same
/// lock.
private final class CaptureSink: @unchecked Sendable {

    /// ~8.5 s of history at 15 Hz.
    private static let waveformCapacity = 128

    private let lock = NSLock()
    private let writer: AudioFileWriter
    private let resampler: SpeechResampler
    private let metrics: AsyncThrowingStream<CaptureMetrics, Error>.Continuation
    private let speech: AsyncStream<SpeechAudioChunk>.Continuation
    private let onFatal: @Sendable (MaikuError) -> Void
    private let emitInterval: AVAudioFrameCount

    private var clock: CaptureClock
    private var speechClock = CaptureClock(sampleRate: SpeechAudioChunk.format.sampleRate)
    private var waveform: [Float] = []
    private var energy: Float = 0
    private var energyFrames: Int = 0
    private var slicePeak: Float = 0
    private var framesSinceEmit: AVAudioFrameCount = 0
    private var isPaused = false
    private var isClosed = false

    init(
        writer: AudioFileWriter,
        resampler: SpeechResampler,
        sampleRate: Double,
        metrics: AsyncThrowingStream<CaptureMetrics, Error>.Continuation,
        speech: AsyncStream<SpeechAudioChunk>.Continuation,
        onFatal: @escaping @Sendable (MaikuError) -> Void
    ) {
        self.writer = writer
        self.resampler = resampler
        self.metrics = metrics
        self.speech = speech
        self.onFatal = onFatal
        self.clock = CaptureClock(sampleRate: sampleRate)
        // ~15 Hz, inside the 10–20 Hz the UI wants (plan §6.2).
        self.emitInterval = AVAudioFrameCount(max(1, sampleRate / 15))
    }

    /// Called on the audio render thread, once per tap buffer.
    ///
    /// ponytail: file I/O and an `NSLock` on the render thread. This is the
    /// standard `AVAudioEngine` tap pattern and is comfortable at 48 kHz mono,
    /// but it can glitch under heavy load. Upgrade path is a lock-free ring
    /// buffer drained by a dedicated writer task.
    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, !isPaused, buffer.frameLength > 0 else { return }

        do {
            try writer.write(buffer)
        } catch {
            // Stop writing but keep what is already on disk: plan §21 rule 12.
            isClosed = true
            writer.close()
            onFatal((error as? MaikuError) ?? .audioFileWriteFailed(error.localizedDescription))
            return
        }
        clock.advance(by: buffer.frameLength)

        let samples = resampler.resample(buffer)
        if !samples.isEmpty {
            let startTime = speechClock.advance(by: AVAudioFrameCount(samples.count))
            speech.yield(SpeechAudioChunk(samples: samples, startTime: startTime))
        }

        let (rms, peak) = AudioLevelMeter.measure(buffer)
        energy += rms * rms * Float(buffer.frameLength)
        energyFrames += Int(buffer.frameLength)
        slicePeak = max(slicePeak, peak)
        framesSinceEmit += buffer.frameLength
        if framesSinceEmit >= emitInterval { emit() }
    }

    /// Caller holds `lock`.
    private func emit() {
        let windowRMS = energyFrames > 0 ? (energy / Float(energyFrames)).squareRoot() : 0
        waveform.append(AudioLevelMeter.normalized(slicePeak))
        if waveform.count > Self.waveformCapacity {
            waveform.removeFirst(waveform.count - Self.waveformCapacity)
        }
        metrics.yield(
            CaptureMetrics(
                elapsed: clock.elapsed,
                level: AudioLevelMeter.normalized(windowRMS),
                peak: slicePeak,
                waveform: waveform))

        energy = 0
        energyFrames = 0
        slicePeak = 0
        framesSinceEmit = 0
    }

    func setPaused(_ paused: Bool) {
        lock.withLock { isPaused = paused }
    }

    var elapsed: TimeInterval {
        lock.withLock { clock.elapsed }
    }

    /// Closes the working file and reports what was preserved. Idempotent.
    @discardableResult
    func close() -> (frames: AVAudioFramePosition, duration: TimeInterval) {
        lock.withLock {
            if !isClosed {
                isClosed = true
                writer.close()
            }
            return (writer.framesWritten, clock.elapsed)
        }
    }
}

// MARK: - Capture

/// Microphone capture. One instance per recording — the streams below finish
/// when it stops and cannot be restarted.
///
/// Everything except the input tap lives inside this actor. The tap is the one
/// exception: Core Audio calls it on a real-time thread, so all of its state is
/// in `CaptureSink`, which the actor only reaches through a lock.
public actor AudioCaptureService {

    /// Throttled snapshots for the UI. Finishes when capture stops; throws the
    /// `MaikuError` that ended it when capture failed. Either way the partial
    /// file survives and `stop()` still reports it.
    public nonisolated let metrics: AsyncThrowingStream<CaptureMetrics, Error>

    /// 16 kHz mono audio for transcription and diarization.
    public nonisolated let speechAudio: AsyncStream<SpeechAudioChunk>

    private nonisolated let metricsContinuation:
        AsyncThrowingStream<CaptureMetrics, Error>.Continuation
    private nonisolated let speechContinuation: AsyncStream<SpeechAudioChunk>.Continuation

    private let engine = AVAudioEngine()
    private var sink: CaptureSink?
    private var captureFormat: AVAudioFormat?
    private var outputURL: URL?
    private var configurationObserver: (any NSObjectProtocol)?
    private var isCapturing = false
    private var isPaused = false
    private var result: CaptureResult?
    private var diskSpaceMonitorTask: Task<Void, Never>?
    private let diskSpaceCheckInterval: Duration
    private let minimumFreeBytesOverride: Int64?

    /// Refuse to start below this. 48 kHz mono Float32 CAF runs at ~192 KB/s, so
    /// this is roughly 45 minutes of capture plus room for the archive and the
    /// database that follow it.
    static let minimumFreeBytes: Int64 = 512 * 1024 * 1024

    private var effectiveMinimumFreeBytes: Int64 { minimumFreeBytesOverride ?? Self.minimumFreeBytes }

    public init() {
        self.init(diskSpaceCheckInterval: .seconds(60), minimumFreeBytesOverride: nil)
    }

    /// Test-only: a shorter check interval and a forced threshold, so the
    /// periodic disk-space monitor (plan §6.2, §9) can be exercised
    /// deterministically instead of depending on the test machine's actual
    /// free space or waiting real minutes between checks.
    init(diskSpaceCheckInterval: Duration, minimumFreeBytesOverride: Int64?) {
        self.diskSpaceCheckInterval = diskSpaceCheckInterval
        self.minimumFreeBytesOverride = minimumFreeBytesOverride

        let metricsStream = AsyncThrowingStream<CaptureMetrics, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        metrics = metricsStream.stream
        metricsContinuation = metricsStream.continuation

        // Bounded on purpose. If the speech stack falls ~20 s behind, live
        // transcription is already lost and the final pass re-reads the file;
        // growing without limit would break plan §18 instead.
        let speechStream = AsyncStream<SpeechAudioChunk>.makeStream(
            bufferingPolicy: .bufferingNewest(256))
        speechAudio = speechStream.stream
        speechContinuation = speechStream.continuation
    }

    /// Seconds of audio captured so far.
    public var elapsedTime: TimeInterval { sink?.elapsed ?? result?.duration ?? 0 }

    /// Starts capture, writing losslessly to `url` (give it a `.caf` path).
    ///
    /// Creates the enclosing directory. Throws before touching the microphone if
    /// permission, hardware or disk space is missing.
    public func start(writingTo url: URL) throws {
        guard !isCapturing, result == nil else {
            throw MaikuError.audioEngineFailed("This capture session has already been used.")
        }
        try MicrophonePermission.check()
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw MaikuError.noMicrophoneFound
        }

        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            throw MaikuError.audioFileWriteFailed(error.localizedDescription)
        }
        try Self.checkFreeSpace(at: directory, minimumFreeBytes: effectiveMinimumFreeBytes)

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MaikuError.noMicrophoneFound
        }
        guard let resampler = SpeechResampler(from: format) else {
            throw MaikuError.audioEngineFailed(
                "Cannot resample \(Int(format.sampleRate)) Hz input to 16 kHz.")
        }

        let writer = try AudioFileWriter(url: url, format: format)
        let sink = CaptureSink(
            writer: writer,
            resampler: resampler,
            sampleRate: format.sampleRate,
            metrics: metricsContinuation,
            speech: speechContinuation,
            onFatal: { [weak self] error in Task { await self?.abort(error) } })

        input.installTap(
            onBus: 0, bufferSize: 4096, format: format, block: Self.tapBlock(for: sink))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            sink.close()
            try? FileManager.default.removeItem(at: url)
            throw MaikuError.audioEngineFailed(error.localizedDescription)
        }

        self.sink = sink
        captureFormat = format
        outputURL = url
        isCapturing = true
        observeConfigurationChanges(expecting: format)
        diskSpaceMonitorTask = Task { [weak self] in await self?.monitorDiskSpace(at: directory) }
    }

    /// Pausing leaves the frame counter alone, so the audio file and the
    /// transcript timeline stay in step across any number of pauses — the file
    /// simply has no frames for the paused interval.
    public func pause() {
        guard isCapturing, !isPaused else { return }
        sink?.setPaused(true)
        engine.pause()
        isPaused = true
    }

    public func resume() throws {
        guard isCapturing, isPaused else { return }
        do {
            try engine.start()
        } catch {
            throw MaikuError.audioEngineFailed(error.localizedDescription)
        }
        sink?.setPaused(false)
        isPaused = false
    }

    /// Stops capture and closes the working file. Idempotent, and still returns
    /// the partial file after a failure — the failure itself was delivered on
    /// `metrics`, and losing captured audio is never acceptable (plan §21).
    ///
    /// Returns `nil` only if capture never started.
    @discardableResult
    public func stop() -> CaptureResult? {
        guard isCapturing else { return result }
        let finished = teardown()
        speechContinuation.finish()
        metricsContinuation.finish()
        return finished
    }

    // MARK: Private

    /// Built outside the actor's isolation on purpose: Core Audio calls this on
    /// its render thread, so it must capture nothing but the lock-guarded sink.
    private nonisolated static func tapBlock(for sink: CaptureSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.receive(buffer) }
    }

    private func abort(_ error: MaikuError) {
        guard isCapturing else { return }
        _ = teardown()
        speechContinuation.finish()
        metricsContinuation.finish(throwing: error)
    }

    @discardableResult
    private func teardown() -> CaptureResult? {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        diskSpaceMonitorTask?.cancel()
        diskSpaceMonitorTask = nil
        isCapturing = false
        isPaused = false

        guard let sink, let url = outputURL, let format = captureFormat else { return nil }
        let closed = sink.close()
        self.sink = nil
        result = CaptureResult(
            url: url, duration: closed.duration, frameCount: closed.frames,
            sampleRate: format.sampleRate)
        return result
    }

    private func observeConfigurationChanges(expecting format: AVAudioFormat) {
        let sampleRate = format.sampleRate
        let channels = format.channelCount
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] _ in
            Task {
                await self?.handleConfigurationChange(sampleRate: sampleRate, channels: channels)
            }
        }
    }

    /// A route change during a recording is either the same device coming back,
    /// or the device we were recording from going away. A different sample rate
    /// cannot be spliced into the open CAF, so that second case ends the
    /// recording with the partial file intact.
    ///
    /// ponytail: no mid-recording device migration. Upgrade path is to close the
    /// current file, open a second one at the new format, and stitch them during
    /// finalization.
    private func handleConfigurationChange(sampleRate: Double, channels: AVAudioChannelCount) {
        guard isCapturing else { return }
        let current = engine.inputNode.inputFormat(forBus: 0)
        guard current.sampleRate == sampleRate, current.channelCount == channels else {
            abort(.microphoneDisconnected)
            return
        }
        // Same device, but the engine stops itself on a configuration change.
        guard !isPaused, !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            abort(.microphoneDisconnected)
        }
    }

    static func checkFreeSpace(at directory: URL) throws {
        try checkFreeSpace(at: directory, minimumFreeBytes: minimumFreeBytes)
    }

    static func checkFreeSpace(at directory: URL, minimumFreeBytes: Int64) throws {
        let values = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        // An unreadable volume is not a reason to refuse to record.
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        guard available >= minimumFreeBytes else {
            throw MaikuError.lowDiskSpace(availableBytes: available)
        }
    }

    /// Re-checks free space every `diskSpaceCheckInterval` for as long as
    /// capture runs (plan §6.2, §9): the start-time check alone only catches
    /// a disk that was already full. Ends the recording the same way any
    /// other fatal condition does — `abort` preserves everything written so
    /// far and reports the reason on `metrics` — rather than writing on
    /// until the volume is actually full and the write itself fails.
    private func monitorDiskSpace(at directory: URL) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: diskSpaceCheckInterval)
            } catch {
                return  // Cancelled during the sleep.
            }
            guard isCapturing else { return }
            do {
                try Self.checkFreeSpace(at: directory, minimumFreeBytes: effectiveMinimumFreeBytes)
            } catch let error as MaikuError {
                abort(error)
                return
            } catch {
                return
            }
        }
    }
}
