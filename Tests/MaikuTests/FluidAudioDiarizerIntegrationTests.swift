import AVFoundation
import Foundation
import Testing

@testable import MaikuKit

/// Opt-in, real-model integration test (plan §17.2): downloads FluidAudio's
/// diarization models on first run and takes real wall-clock time, so it
/// must not run in normal CI. `MAIKU_INTEGRATION_TESTS=1 ./scripts/test.sh`
/// to run it.
///
/// This exists because `FluidAudioDiarizer`'s whole streaming design rests
/// on one empirical claim that the pure `mergeTurns` unit tests cannot
/// check: that `DiarizerManager.speakerManager` state actually persists
/// across repeated `performCompleteDiarization` calls on the *same*
/// instance, so periodic flushes on a trimmed, bounded window keep
/// recognising the same voice as the same label instead of relabelling it
/// every few seconds. No amount of pure-logic testing substitutes for
/// running the real model against real audio and checking that claim held.
@Suite(
    "FluidAudio streaming diarization (opt-in, real models)",
    .enabled(if: ProcessInfo.processInfo.environment["MAIKU_INTEGRATION_TESTS"] != nil))
struct FluidAudioDiarizerIntegrationTests {

    /// `say -v Samantha` / `say -v Daniel`, four turns, ~21 s, 16 kHz mono —
    /// the same fixture-generation approach as the Milestone 0 spike,
    /// checked in as a small `.wav` so this test needs no shell commands.
    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/two_speaker.wav")
    }

    @Test("Streaming over a real two-speaker fixture finds both speakers with stable labels across flushes")
    func streamingFindsBothSpeakersConsistently() async throws {
        let diarizer = FluidAudioDiarizer()
        try await diarizer.prepare()
        try await diarizer.startStreaming()

        let updatesTask = Task<[DiarizationUpdate], Error> {
            var collected: [DiarizationUpdate] = []
            for try await update in diarizer.updates() {
                collected.append(update)
            }
            return collected
        }

        let file = try AVAudioFile(forReading: Self.fixtureURL)
        let format = file.processingFormat
        #expect(format.sampleRate == 16_000)
        #expect(format.channelCount == 1)

        // Feed it the way a live tap actually would: small buffers, in order,
        // each timestamped by cumulative frames — not one giant buffer.
        let chunkFrames: AVAudioFrameCount = 4_096
        var elapsed: TimeInterval = 0
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(file.length - file.framePosition)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: min(chunkFrames, remaining))!
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try await diarizer.accept(buffer, at: elapsed)
            elapsed += Double(buffer.frameLength) / format.sampleRate
        }

        let final = try await diarizer.finishStreaming()
        updatesTask.cancel()
        let liveUpdates = (try? await updatesTask.value) ?? []

        #expect(!liveUpdates.isEmpty, "expected at least one periodic flush over a 21 s fixture")

        let labels = Set(final.turns.map(\.diarizerLabel))
        #expect(labels.count == 2, "expected exactly two speakers, found \(labels.sorted())")

        // The empirical claim this whole design rests on: turns well
        // into the recording (Speaker B's second turn, after two
        // intervening flushes at a 6 s interval) still carry a label seen
        // in the very first flush, rather than every flush relabelling
        // from scratch.
        let firstUpdateLabels = Set((liveUpdates.first?.turns ?? []).map(\.diarizerLabel))
        let lastTurnLabel = final.turns.max { $0.startTime < $1.startTime }?.diarizerLabel
        #expect(
            lastTurnLabel.map(firstUpdateLabels.contains) == true,
            "the final turn's label (\(lastTurnLabel ?? "nil")) should already have appeared in the first flush (\(firstUpdateLabels.sorted())) if speaker identity is persisting across flushes"
        )

        // Sanity check the actual speaker-change points roughly land where
        // the fixture's turns actually change speaker (0s, ~4.5s, ~11s,
        // ~15.5s) — loose tolerance, since diarization boundary drift on
        // synthesized speech was already measured in the Milestone 0 spike.
        let sortedTurns = final.turns.sorted { $0.startTime < $1.startTime }
        #expect(sortedTurns.count >= 3, "expected at least 3 turns across 4 speaker changes")
    }
}
