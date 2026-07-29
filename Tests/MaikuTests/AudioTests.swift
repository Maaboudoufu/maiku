import AVFoundation
import Foundation
import Testing

@testable import MaikuKit

// MARK: - Fixtures
//
// Everything here is synthesised. No test in this file opens an input device,
// starts the engine, or asks for permission, so the suite runs headless.

/// The shape `AVAudioEngine` hands an input tap: standard deinterleaved Float32.
private func deviceFormat(
    _ sampleRate: Double, channels: AVAudioChannelCount = 1, interleaved: Bool = false
) -> AVAudioFormat {
    AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels,
        interleaved: interleaved)!
}

private func pcmBuffer(
    frames: Int,
    sampleRate: Double = 48_000,
    channels: AVAudioChannelCount = 1,
    interleaved: Bool = false,
    fill: (_ channel: Int, _ frame: Int) -> Float = { _, _ in 0 }
) -> AVAudioPCMBuffer {
    let format = deviceFormat(sampleRate, channels: channels, interleaved: interleaved)
    // frameCapacity must be positive even when the buffer carries no frames.
    let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1)))!
    buffer.frameLength = AVAudioFrameCount(frames)
    let data = buffer.floatChannelData!
    let step = interleaved ? Int(channels) : 1
    for channel in 0..<Int(channels) {
        let samples = interleaved ? data[0] + channel : data[channel]
        for frame in 0..<frames { samples[frame * step] = fill(channel, frame) }
    }
    return buffer
}

/// A device handing back integer samples, which the meter and the writer both
/// have to refuse rather than reinterpret. Filled full scale on purpose: a zero
/// reading then proves the format was checked, not that the audio was silent.
private func int16Buffer(frames: Int, sampleRate: Double = 48_000) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    buffer.int16ChannelData!.pointee.update(repeating: .max, count: frames)
    return buffer
}

/// A 1 kHz tone. Buffer lengths below are whole numbers of periods, so
/// concatenating buffers produces one continuous tone with no phase jump.
private func sineBuffer(frames: Int, sampleRate: Double = 48_000, amplitude: Float = 1)
    -> AVAudioPCMBuffer
{
    pcmBuffer(frames: frames, sampleRate: sampleRate) { _, frame in
        amplitude * Float(sin(2 * Double.pi * 1_000 * Double(frame) / sampleRate))
    }
}

/// RMS of a pure sine, the value the meter should report for full scale.
private let sineRMS = 1 / Float(2).squareRoot()

private func isClose(_ a: Float, _ b: Float, tolerance: Float = 1e-5) -> Bool {
    abs(a - b) <= tolerance
}

private func isClose(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
    abs(a - b) <= tolerance
}

/// A unique directory, removed however `body` returns — a failing test must not
/// leave recordings behind in the temporary volume.
private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "maiku-audio-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

// MARK: - Level meter

@Suite("Audio level meter")
struct AudioLevelMeterTests {

    @Test("Silence reads zero on both meters")
    func silence() {
        let (rms, peak) = AudioLevelMeter.measure(pcmBuffer(frames: 1_024))
        #expect(rms == 0)
        #expect(peak == 0)
        #expect(AudioLevelMeter.normalized(rms) == 0)
    }

    @Test("A full-scale sine reads 1/√2 RMS and 1.0 peak")
    func fullScaleSine() {
        let (rms, peak) = AudioLevelMeter.measure(sineBuffer(frames: 4_800))
        #expect(isClose(rms, sineRMS, tolerance: 1e-4), "rms \(rms)")
        #expect(isClose(peak, 1, tolerance: 1e-4), "peak \(peak)")

        // The documented mapping is dBFS over a −60 dB floor, not linear.
        let level = AudioLevelMeter.normalized(rms)
        #expect(isClose(level, (20 * log10(rms) + 60) / 60, tolerance: 1e-6))
        #expect(level > 0.9, "a full-scale tone must peg the bar near the top")
    }

    @Test("Half amplitude lands between silence and full scale")
    func halfAmplitude() {
        let full = AudioLevelMeter.measure(sineBuffer(frames: 4_800))
        let half = AudioLevelMeter.measure(sineBuffer(frames: 4_800, amplitude: 0.5))

        #expect(isClose(half.rms, full.rms / 2, tolerance: 1e-4), "rms \(half.rms)")
        #expect(isClose(half.peak, 0.5, tolerance: 1e-4), "peak \(half.peak)")

        let quiet = AudioLevelMeter.normalized(half.rms)
        let loud = AudioLevelMeter.normalized(full.rms)
        #expect(quiet > 0 && quiet < loud, "quiet \(quiet), loud \(loud)")
        // Halving amplitude is −6.02 dB, a tenth of the 60 dB scale.
        #expect(isClose(loud - quiet, 6.0206 / 60, tolerance: 1e-3))
    }

    @Test("A zero-frame buffer measures zero rather than NaN")
    func emptyBuffer() {
        let (rms, peak) = AudioLevelMeter.measure(pcmBuffer(frames: 0))
        #expect(rms == 0 && peak == 0)
        #expect(rms.isFinite && peak.isFinite)
        #expect(AudioLevelMeter.normalized(rms).isFinite)
    }

    @Test("A buffer the meter cannot read measures zero instead of garbage")
    func nonFloatBuffer() {
        let (rms, peak) = AudioLevelMeter.measure(int16Buffer(frames: 512))
        #expect(rms == 0 && peak == 0)
    }

    @Test("The decibel mapping is bounded and never NaN")
    func normalizationBounds() {
        #expect(AudioLevelMeter.normalized(0) == 0)
        #expect(AudioLevelMeter.normalized(-1) == 0, "a negative amplitude is not −∞ dB")
        #expect(AudioLevelMeter.normalized(1) == 1)
        #expect(AudioLevelMeter.normalized(4) == 1, "clipping pegs the bar, it does not overflow")
        #expect(AudioLevelMeter.normalized(0.0005) == 0, "−66 dBFS is under the −60 dB floor")
        #expect(AudioLevelMeter.normalized(0.5, floorDB: 0) == 0, "a zero floor would divide by 0")

        for amplitude in stride(from: Float(0), through: 2, by: 0.05) {
            let value = AudioLevelMeter.normalized(amplitude)
            #expect(value.isFinite && value >= 0 && value <= 1, "normalized(\(amplitude)) \(value)")
        }
    }

    @Test("Multi-channel input averages power, and peak stays the loudest channel")
    func deinterleavedChannels() {
        let buffer = pcmBuffer(frames: 4_800, channels: 2) { channel, frame in
            channel == 0 ? Float(sin(2 * Double.pi * 1_000 * Double(frame) / 48_000)) : 0
        }
        let (rms, peak) = AudioLevelMeter.measure(buffer)
        // Mean square of (0.5, 0) is 0.25.
        #expect(isClose(rms, 0.5, tolerance: 1e-4), "rms \(rms)")
        #expect(isClose(peak, 1, tolerance: 1e-4), "peak \(peak)")
    }

    @Test("Interleaved input is measured across the whole interleaved block")
    func interleavedChannels() {
        let buffer = pcmBuffer(frames: 512, channels: 2, interleaved: true) { channel, _ in
            channel == 0 ? 0.8 : -0.4
        }
        let (rms, peak) = AudioLevelMeter.measure(buffer)
        #expect(isClose(rms, Float(0.4).squareRoot(), tolerance: 1e-5), "rms \(rms)")
        #expect(isClose(peak, 0.8), "peak is magnitude, so a negative sample still counts")
    }
}

// MARK: - Timeline

/// Plan §17.1: pause/resume timestamp accounting. The clock is driven by frames
/// that reached the file, never by wall clock, so a pause of any length cannot
/// shift the transcript against the audio.
@Suite("Capture clock")
struct CaptureClockTests {

    @Test("Elapsed time is captured frames, not wall clock")
    func framesAreTheClock() {
        var clock = CaptureClock(sampleRate: 48_000)
        #expect(clock.elapsed == 0)
        clock.advance(by: 24_000)
        #expect(clock.elapsed == 0.5)
        clock.advance(by: 24_000)
        #expect(clock.elapsed == 1)
        #expect(clock.frames == 48_000)
    }

    @Test("Pausing adds no time and resuming opens no gap")
    func pauseResumeAccounting() {
        // 2_000 frames at 16 kHz is 0.125 s — exact in binary, so these
        // comparisons are about the accounting, not about float tolerance.
        var clock = CaptureClock(sampleRate: 16_000)
        var starts: [TimeInterval] = []
        for _ in 0..<3 { starts.append(clock.advance(by: 2_000)) }

        // Paused: the tap drops every buffer, so however long the user waits the
        // timeline does not move.
        #expect(clock.elapsed == 0.375)

        // Resumed: the next buffer starts exactly where the last one ended.
        starts.append(clock.advance(by: 2_000))
        #expect(starts == [0, 0.125, 0.25, 0.375], "a pause must not insert a gap")
        #expect(clock.elapsed == 0.5)
        #expect(clock.frames == 8_000, "the paused interval contributes no frames")
    }

    @Test("Every chunk starts where the previous one ended, whatever the buffer sizes")
    func contiguousStartTimes() {
        var clock = CaptureClock(sampleRate: 16_000)
        var written: AVAudioFrameCount = 0
        for size in [512, 4_096, 1, 8_000, 333] as [AVAudioFrameCount] {
            let start = clock.advance(by: size)
            #expect(start == Double(written) / 16_000)
            written += size
        }
        #expect(clock.frames == AVAudioFramePosition(written))
        #expect(clock.elapsed == Double(written) / 16_000)
    }

    @Test("Dropped buffers shorten the timeline instead of desynchronising it")
    func droppedBuffers() {
        var kept = CaptureClock(sampleRate: 16_000)
        var dropped = CaptureClock(sampleRate: 16_000)
        for index in 0..<4 {
            kept.advance(by: 1_024)
            // The third buffer never reaches the tap.
            if index != 2 { dropped.advance(by: 1_024) }
        }
        #expect(dropped.elapsed < kept.elapsed)
        #expect(isClose(kept.elapsed - dropped.elapsed, Double(1_024) / 16_000))
        #expect(dropped.frames == 3_072, "the timeline matches the file, not the wall clock")
    }

    @Test("A clock with no sample rate reports zero rather than infinity")
    func zeroSampleRate() {
        var clock = CaptureClock(sampleRate: 0)
        clock.advance(by: 1_024)
        #expect(clock.elapsed == 0)
        #expect(clock.elapsed.isFinite)
    }
}

// MARK: - Speech audio

@Suite("Speech resampler")
struct SpeechResamplerTests {

    @Test("48 kHz input becomes 16 kHz mono at a third of the frames")
    func downsampleRatio() throws {
        let resampler = try #require(SpeechResampler(from: deviceFormat(48_000)))
        var produced = 0
        for _ in 0..<10 {
            produced += resampler.resample(sineBuffer(frames: 4_800)).count
        }
        // One second in. Converter priming withholds a filter's worth of frames
        // once, at the start; nothing may invent frames that were never captured.
        #expect(produced > 15_000 && produced <= 16_100, "produced \(produced)")
    }

    @Test("Resampling preserves the signal, not just the frame count")
    func signalSurvives() throws {
        let resampler = try #require(SpeechResampler(from: deviceFormat(48_000)))
        var samples: [Float] = []
        // 1 kHz is far under the 8 kHz Nyquist limit of the target rate, so the
        // anti-alias filter should leave its level alone.
        for _ in 0..<10 { samples += resampler.resample(sineBuffer(frames: 4_800)) }

        let buffer = try #require(SpeechAudioChunk(samples: samples, startTime: 0).makeBuffer())
        let (rms, peak) = AudioLevelMeter.measure(buffer)
        #expect(isClose(rms, sineRMS, tolerance: 0.02), "rms \(rms)")
        #expect(peak <= 1.05, "peak \(peak)")
    }

    @Test("An empty buffer produces nothing")
    func emptyInput() throws {
        let resampler = try #require(SpeechResampler(from: deviceFormat(48_000)))
        #expect(resampler.resample(pcmBuffer(frames: 0)).isEmpty)
        // …and does not poison the converter for the next real buffer.
        #expect(!resampler.resample(sineBuffer(frames: 4_800)).isEmpty)
    }

    @Test("Stereo device input is accepted and comes back mono")
    func stereoInput() throws {
        let resampler = try #require(SpeechResampler(from: deviceFormat(48_000, channels: 2)))
        let buffer = pcmBuffer(frames: 4_800, channels: 2) { _, frame in
            Float(sin(2 * Double.pi * 1_000 * Double(frame) / 48_000))
        }
        // 0.1 s of stereo in, 0.1 s of mono out — the two channels are downmixed,
        // not concatenated. A single isolated call undershoots the ideal 1_600
        // by the converter's one-time filter-priming latency (~240 samples,
        // reproduced identically for a mono-only conversion of the same size),
        // which is why the lower bound sits well below 1_600 rather than
        // tight against it; a real downmix failure would miss by far more.
        let samples = resampler.resample(buffer)
        #expect(samples.count > 1_200 && samples.count <= 1_664, "produced \(samples.count)")
    }

    @Test("Chunk start times stay contiguous across the resampled stream")
    func chunkTimeline() throws {
        let resampler = try #require(SpeechResampler(from: deviceFormat(44_100)))
        var clock = CaptureClock(sampleRate: SpeechAudioChunk.format.sampleRate)
        var chunks: [SpeechAudioChunk] = []
        for _ in 0..<8 {
            let samples = resampler.resample(sineBuffer(frames: 4_410, sampleRate: 44_100))
            guard !samples.isEmpty else { continue }
            chunks.append(
                SpeechAudioChunk(
                    samples: samples,
                    startTime: clock.advance(by: AVAudioFrameCount(samples.count))))
        }

        #expect(chunks.count > 1)
        #expect(chunks.first?.startTime == 0)
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            let end = previous.startTime + Double(previous.samples.count) / 16_000
            #expect(isClose(next.startTime, end), "\(next.startTime) should follow \(end)")
        }
    }

    @Test("A speech chunk round-trips through a 16 kHz mono buffer")
    func chunkRoundTrip() throws {
        let samples = (0..<1_600).map { Float(sin(2 * Double.pi * 440 * Double($0) / 16_000)) / 2 }
        let buffer = try #require(SpeechAudioChunk(samples: samples, startTime: 2).makeBuffer())

        #expect(buffer.frameLength == 1_600)
        #expect(buffer.format.sampleRate == 16_000)
        #expect(buffer.format.channelCount == 1)
        #expect(
            Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 1_600)) == samples)
        #expect(
            SpeechAudioChunk(samples: [], startTime: 0).makeBuffer() == nil,
            "an empty chunk has no buffer to give the speech stack")
    }
}

// MARK: - Working file

@Suite("Audio file writer")
struct AudioFileWriterTests {

    @Test("A closed file reads back with every frame, its rate and its channels")
    func roundTrip() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "capture.caf")
            let writer = try AudioFileWriter(url: url, format: deviceFormat(48_000))
            for _ in 0..<10 { try writer.write(sineBuffer(frames: 4_800)) }
            #expect(writer.framesWritten == 48_000)
            writer.close()

            let file = try AVAudioFile(forReading: url)
            #expect(file.length == 48_000)
            #expect(file.fileFormat.sampleRate == 48_000)
            #expect(file.fileFormat.channelCount == 1)

            let counted = try AudioFileWriter.frameCount(at: url)
            #expect(counted == 48_000)

            // Not just the right size — the right audio. `read(into:)` is not
            // guaranteed to fill the buffer in one call, so drain in a loop.
            var totalRead: AVAudioFramePosition = 0
            var samples: [Float] = []
            while file.framePosition < file.length {
                let remaining = AVAudioFrameCount(file.length - file.framePosition)
                let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: remaining)!
                try file.read(into: chunk)
                guard chunk.frameLength > 0 else { break }
                totalRead += AVAudioFramePosition(chunk.frameLength)
                samples.append(
                    contentsOf: UnsafeBufferPointer(
                        start: chunk.floatChannelData![0], count: Int(chunk.frameLength)))
            }
            #expect(totalRead == 48_000)
            let rms = (samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count)).squareRoot()
            #expect(isClose(rms, sineRMS, tolerance: 1e-4))
        }
    }

    @Test("Stereo at 44.1 kHz survives the round trip too")
    func stereoRoundTrip() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "stereo.caf")
            let format = deviceFormat(44_100, channels: 2)
            let writer = try AudioFileWriter(url: url, format: format)
            for _ in 0..<2 {
                try writer.write(
                    pcmBuffer(frames: 4_410, sampleRate: 44_100, channels: 2) { channel, frame in
                        Float(sin(2 * Double.pi * 1_000 * Double(frame) / 44_100))
                            * (channel == 0 ? 1 : 0.5)
                    })
            }
            writer.close()

            let file = try AVAudioFile(forReading: url)
            #expect(file.length == 8_820)
            #expect(file.fileFormat.sampleRate == 44_100)
            #expect(file.fileFormat.channelCount == 2)
        }
    }

    @Test("A format change mid-recording is refused instead of killing the process")
    func formatMismatchIsRefused() throws {
        try withTemporaryDirectory { directory in
            let writer = try AudioFileWriter(
                url: directory.appending(path: "capture.caf"), format: deviceFormat(48_000))
            let mismatch = MaikuError.audioFileWriteFailed(
                "The input format changed mid-recording.")

            // Each of these would raise an uncatchable Objective-C exception if it
            // reached AVAudioFile, taking the recording down with the process.
            #expect(throws: mismatch) {
                try writer.write(sineBuffer(frames: 512, sampleRate: 44_100))
            }
            #expect(throws: mismatch) { try writer.write(pcmBuffer(frames: 512, channels: 2)) }
            #expect(throws: mismatch) { try writer.write(int16Buffer(frames: 512)) }
            #expect(writer.framesWritten == 0)

            // An empty buffer is a no-op, not a failure.
            try writer.write(pcmBuffer(frames: 0))
            #expect(writer.framesWritten == 0)

            try writer.write(pcmBuffer(frames: 256))
            #expect(writer.framesWritten == 256)
        }
    }

    @Test("Writing after close fails loudly, and what was written is still readable")
    func closedWriter() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "capture.caf")
            let writer = try AudioFileWriter(url: url, format: deviceFormat(48_000))
            try writer.write(sineBuffer(frames: 4_800))
            writer.close()
            writer.close()  // idempotent

            let closed = MaikuError.audioFileWriteFailed("The recording file is already closed.")
            #expect(throws: closed) { try writer.write(sineBuffer(frames: 4_800)) }
            #expect(writer.framesWritten == 4_800)

            let counted = try AudioFileWriter.frameCount(at: url)
            #expect(counted == 4_800, "the audio captured before the failure must survive")
        }
    }

    @Test("A non-file URL never becomes a recording")
    func rejectsNonFileURL() {
        #expect(throws: MaikuError.self) {
            try AudioFileWriter(
                url: URL(string: "https://example.com/capture.caf")!, format: deviceFormat(48_000))
        }
    }

    @Test("An unreadable file is an integrity failure, not a crash")
    func frameCountRejectsRubbish() throws {
        try withTemporaryDirectory { directory in
            let missing = directory.appending(path: "missing.caf")
            #expect(throws: MaikuError.fileIntegrityCheckFailed(path: missing.path)) {
                try AudioFileWriter.frameCount(at: missing)
            }

            // Plan §6.5 step 1: validate before spending minutes transcribing.
            let junk = directory.appending(path: "junk.caf")
            try Data("not audio".utf8).write(to: junk)
            #expect(throws: MaikuError.fileIntegrityCheckFailed(path: junk.path)) {
                try AudioFileWriter.frameCount(at: junk)
            }
        }
    }
}

// MARK: - Preflight

@Suite("Capture preflight")
struct CapturePreflightTests {

    @Test("The disk-space floor covers a long recording at the working format")
    func diskSpaceFloor() {
        // 48 kHz mono Float32 CAF is 192 KB/s (plan §6.2).
        #expect(AudioCaptureService.minimumFreeBytes >= 48_000 * 4 * 45 * 60)
    }

    @Test("The free-space gate matches what the volume reports")
    func freeSpaceGate() throws {
        try withTemporaryDirectory { directory in
            let capacity = try directory.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage
            guard let capacity else { return }  // unreadable volume: covered below

            if capacity >= AudioCaptureService.minimumFreeBytes {
                try AudioCaptureService.checkFreeSpace(at: directory)
            } else {
                #expect(throws: MaikuError.self) {
                    try AudioCaptureService.checkFreeSpace(at: directory)
                }
            }
        }
    }

    @Test("A volume that cannot be queried does not block recording")
    func unreadableVolume() throws {
        // Refusing to record because a capacity read failed would lose the
        // meeting for no reason.
        try AudioCaptureService.checkFreeSpace(at: URL(fileURLWithPath: "/dev/null/nowhere"))
    }

    @Test("An explicit threshold overrides the default, in both directions")
    func explicitThresholdOverride() throws {
        // Plan §6.2/§9's periodic re-check (`monitorDiskSpace`) reuses this
        // overload with an instance-level threshold rather than the static
        // default, so both directions have to work independent of it.
        try withTemporaryDirectory { directory in
            let capacity = try directory.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage
            guard let capacity, capacity > 0 else { return }  // unreadable volume: covered above

            // A threshold no real volume clears.
            #expect(throws: MaikuError.self) {
                try AudioCaptureService.checkFreeSpace(at: directory, minimumFreeBytes: .max)
            }
            // A threshold every volume clears.
            try AudioCaptureService.checkFreeSpace(at: directory, minimumFreeBytes: 1)
        }
    }

    @Test("check() throws exactly when the current authorisation is not granted")
    func permissionMapping() {
        // Reads the real authorisation state, which needs no microphone and
        // never prompts — so this behaves the same on CI and on a dev Mac.
        let status = MicrophonePermission.status
        #expect(MicrophonePermission.isGranted == (status == .granted))
        do {
            try MicrophonePermission.check()
            #expect(status == .granted)
        } catch {
            let expected: MaikuError =
                status == .denied ? .microphonePermissionDenied : .microphonePermissionUndetermined
            #expect(error as? MaikuError == expected, "status \(status) mapped to \(error)")
        }
    }

    @Test("A capture that never started stops cleanly and reports no audio")
    func stopBeforeStart() async {
        let service = AudioCaptureService()
        #expect(await service.stop() == nil)
        #expect(await service.stop() == nil, "stop is idempotent")
        #expect(await service.elapsedTime == 0)
    }
}
