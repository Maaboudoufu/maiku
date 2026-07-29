import AVFoundation
import Foundation
import Testing

@testable import MaikuKit

/// A short, real, playable audio file — `AVAudioPlayer` needs an actual
/// decodable file on disk, not a synthesized buffer in memory.
private func withPlayableFixture<T>(
    seconds: TimeInterval = 1, _ body: (URL) async throws -> T
) async throws -> T {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "maiku-playback-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appending(path: "fixture.caf")
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let writer = try AudioFileWriter(url: url, format: format)
    let frameCount = AVAudioFrameCount(seconds * format.sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    let channel = buffer.floatChannelData![0]
    for frame in 0..<Int(frameCount) {
        channel[frame] = 0.2 * Float(sin(2 * Double.pi * 440 * Double(frame) / format.sampleRate))
    }
    try writer.write(buffer)
    writer.close()

    return try await body(url)
}

private func isClose(_ a: Double, _ b: Double, tolerance: Double) -> Bool {
    abs(a - b) <= tolerance
}

@Suite("Audio playback service")
struct AudioPlaybackServiceTests {

    @Test("Loading a file reports its duration with zero elapsed time")
    func loadReportsDuration() async throws {
        try await withPlayableFixture(seconds: 1) { url in
            let service = AudioPlaybackService()
            try await service.load(url: url)
            let loaded = try #require(await service.currentState())
            #expect(loaded.currentTime == 0)
            #expect(isClose(loaded.duration, 1, tolerance: 0.05))
            #expect(!loaded.isPlaying)
        }
    }

    @Test("The state stream reports the same thing currentState() does")
    func streamAgreesWithCurrentState() async throws {
        try await withPlayableFixture(seconds: 1) { url in
            let service = AudioPlaybackService()
            try await service.load(url: url)
            var iterator = service.state.makeAsyncIterator()
            let streamed = try #require(await iterator.next())
            let direct = try #require(await service.currentState())
            #expect(streamed == direct)
        }
    }

    @Test("Playing advances current time; pausing stops it")
    func playAdvancesTimePauseStopsIt() async throws {
        try await withPlayableFixture(seconds: 2) { url in
            let service = AudioPlaybackService()
            try await service.load(url: url)
            try await service.play()
            try await Task.sleep(for: .milliseconds(300))
            await service.pause()

            let paused = try #require(await service.currentState())
            #expect(!paused.isPlaying)
            #expect(paused.currentTime > 0)

            // A paused player must not keep advancing.
            try await Task.sleep(for: .milliseconds(150))
            #expect(await service.currentState()?.currentTime == paused.currentTime)
        }
    }

    @Test("Seeking jumps to the requested time immediately")
    func seekJumps() async throws {
        try await withPlayableFixture(seconds: 2) { url in
            let service = AudioPlaybackService()
            try await service.load(url: url)
            await service.seek(to: 1.2)
            let state = try #require(await service.currentState())
            #expect(isClose(state.currentTime, 1.2, tolerance: 0.05))
        }
    }

    @Test("Seeking past the end clamps just short of the file's duration")
    func seekClampsToDuration() async throws {
        // AVAudioPlayer silently ignores an assignment to currentTime at or
        // beyond duration (verified empirically), so the ceiling this clamps
        // to sits strictly under it — see the comment on seek(to:).
        try await withPlayableFixture(seconds: 1) { url in
            let service = AudioPlaybackService()
            try await service.load(url: url)
            await service.seek(to: 500)
            let state = try #require(await service.currentState())
            #expect(isClose(state.currentTime, 0.95, tolerance: 0.05))
        }
    }

    @Test("Setting the rate is reflected back in state")
    func setRateIsReflected() async throws {
        try await withPlayableFixture(seconds: 1) { url in
            let service = AudioPlaybackService()
            try await service.load(url: url)
            await service.setRate(1.5)
            #expect(await service.currentState()?.rate == 1.5)
        }
    }

    @Test("Playing without loading throws, rather than crashing")
    func playWithoutLoadThrows() async throws {
        let service = AudioPlaybackService()
        await #expect(throws: MaikuError.self) {
            try await service.play()
        }
    }

    @Test("Loading a file that does not exist throws a file-integrity error")
    func loadingMissingFileThrows() async {
        let service = AudioPlaybackService()
        await #expect(throws: MaikuError.self) {
            try await service.load(url: URL(fileURLWithPath: "/nonexistent/nowhere.caf"))
        }
    }

    @Test("stop() lets a fresh load() start over cleanly")
    func stopThenReloadWorks() async throws {
        try await withPlayableFixture(seconds: 1) { firstURL in
            try await withPlayableFixture(seconds: 1) { secondURL in
                let service = AudioPlaybackService()
                try await service.load(url: firstURL)
                try await service.play()
                await service.stop()

                try await service.load(url: secondURL)
                #expect(await service.currentState()?.currentTime == 0)
            }
        }
    }
}
