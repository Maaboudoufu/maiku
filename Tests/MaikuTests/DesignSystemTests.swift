import Foundation
import Testing

@testable import MaikuKit

/// One value per `ClawdState` case. The enum has associated values so it cannot
/// be `CaseIterable`; this list is what makes "every state" testable, and adding
/// a case without adding it here shows up as an uncovered filename below.
private let allStates: [ClawdState] = [
    .idle,
    .ready,
    .listening(level: 0.5),
    .paused,
    .transcribing,
    .organizing(progress: 0.5),
    .complete,
    .error,
    .lmStudioDisconnected,
]

@Suite("Clawd asset manifest")
struct ClawdManifestTests {

    /// The filenames are a contract with whoever supplies authorized artwork
    /// (plan §14). A rename here silently falls back to the placeholder, so the
    /// list is asserted literally rather than derived.
    @Test("Manifest lists exactly the filenames plan §14 names, in order")
    func fileNamesMatchSpec() {
        #expect(
            ClawdAssetManifest.standard.fileNames == [
                "clawd_idle_notebook.png",
                "clawd_ready_mic.png",
                "clawd_listening_01.png",
                "clawd_listening_02.png",
                "clawd_listening_03.png",
                "clawd_listening_04.png",
                "clawd_listening_05.png",
                "clawd_listening_06.png",
                "clawd_listening_07.png",
                "clawd_listening_08.png",
                "clawd_paused.png",
                "clawd_transcribing_01.png",
                "clawd_transcribing_02.png",
                "clawd_organizing_01.png",
                "clawd_organizing_02.png",
                "clawd_organizing_03.png",
                "clawd_complete.png",
                "clawd_error.png",
                "clawd_lmstudio_disconnected.png",
            ])
    }

    @Test("Every state resolves to frames the manifest declares")
    func everyStateHasFrames() {
        let manifest = ClawdAssetManifest.standard
        for state in allStates {
            let entry = manifest.entry(for: state)
            #expect(!entry.frames.isEmpty, "\(state) has no frames")
            #expect(entry.frameDuration > 0, "\(state) would divide by zero when animating")
            for frame in entry.frames {
                #expect(manifest.fileNames.contains(frame), "\(frame) is not in the manifest")
            }
        }
    }

    /// Catches the other direction: a file the manifest promises but no state
    /// ever draws is art someone would be asked to produce for nothing.
    @Test("Every declared filename is used by some state")
    func noOrphanFilenames() {
        let manifest = ClawdAssetManifest.standard
        let used = Set(allStates.flatMap { manifest.entry(for: $0).frames })
        #expect(used == Set(manifest.fileNames))
    }

    /// Regression test for a real bug: installing one state's art must not
    /// hide the "Placeholder art" badge for a state that still has none —
    /// art lands one state at a time (README), so this has to be checked
    /// per entry, not with one app-wide flag.
    @Test("isFullyInstalled is independent per entry, and a partial sequence still reads as not installed")
    @MainActor
    func isFullyInstalledIsPerEntryNotGlobal() {
        let installedNames: Set<String> = ["__test_installed_a__", "__test_installed_b__"]
        let resolve: (String) -> Bool = { installedNames.contains($0) }

        let fullyInstalled = ClawdAssetManifest.Entry(["__test_installed_a__", "__test_installed_b__"])
        let fullyMissing = ClawdAssetManifest.Entry(["__test_missing_a__", "__test_missing_b__"])
        let partiallyInstalled = ClawdAssetManifest.Entry(["__test_installed_a__", "__test_missing_a__"])

        #expect(ClawdArtwork.isFullyInstalled(fullyInstalled, resolve: resolve))
        #expect(!ClawdArtwork.isFullyInstalled(fullyMissing, resolve: resolve))
        #expect(
            !ClawdArtwork.isFullyInstalled(partiallyInstalled, resolve: resolve),
            "one missing frame in a sequence must not read as fully installed")
    }

    @Test("Frame index cycles and stays in bounds")
    func frameIndexInBounds() {
        let entry = ClawdAssetManifest.Entry(["a", "b", "c"], frameDuration: 0.1)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let indices = (0..<12).map { step in
            ClawdView.frameIndex(at: start.addingTimeInterval(Double(step) * 0.1), entry: entry)
        }
        #expect(indices.allSatisfy { (0..<3).contains($0) })
        #expect(Set(indices).count == 3, "the sequence should visit every frame")
        // A date far in the past yields a negative tick count; the index must
        // still be a valid subscript.
        let past = Date(timeIntervalSinceReferenceDate: -12_345.6)
        #expect((0..<3).contains(ClawdView.frameIndex(at: past, entry: entry)))
        // A still holds frame 0 rather than animating.
        #expect(ClawdView.frameIndex(at: start, entry: ClawdAssetManifest.Entry(["only"])) == 0)
    }
}

@Suite("Clawd state descriptions")
struct ClawdStateTests {

    @Test("Each state has a distinct, non-empty VoiceOver label and caption")
    func labelsAreDistinct() {
        let labels = allStates.map(\.accessibilityLabel)
        #expect(labels.allSatisfy { !$0.isEmpty })
        #expect(Set(labels).count == allStates.count, "two states share a label")

        let captions = allStates.map(\.caption)
        #expect(captions.allSatisfy { !$0.isEmpty })
        #expect(Set(captions).count == allStates.count, "two states share a caption")
    }

    /// The label must not move while a level or progress value churns, or
    /// VoiceOver re-announces the whole sentence several times a second.
    @Test("Label is stable across payloads; the value carries the number")
    func payloadGoesInValue() {
        #expect(
            ClawdState.listening(level: 0).accessibilityLabel
                == ClawdState.listening(level: 1).accessibilityLabel)
        #expect(ClawdState.listening(level: 0.5).accessibilityValue == "Input level 50 percent")
        #expect(ClawdState.organizing(progress: nil).accessibilityValue == nil)
        #expect(ClawdState.organizing(progress: 0.25).accessibilityValue == "25 percent")
        #expect(ClawdState.idle.accessibilityValue == nil)
    }

    @Test("Hostile levels and progress values are clamped, not trusted")
    func clampsGarbage() {
        // Non-finite reads as silence, not as a full meter: a NaN level means the
        // audio path produced nothing usable, and a pinned bar would lie.
        #expect(ClawdState.listening(level: .nan).accessibilityValue == "Input level 0 percent")
        #expect(ClawdState.listening(level: .infinity).accessibilityValue == "Input level 0 percent")
        #expect(ClawdState.listening(level: -5).accessibilityValue == "Input level 0 percent")
        #expect(ClawdState.listening(level: 9).accessibilityValue == "Input level 100 percent")
        #expect(ClawdState.organizing(progress: 42).accessibilityValue == "100 percent")
        #expect(ClawdState.organizing(progress: .nan).accessibilityValue == "0 percent")
    }
}

@Suite("Pixel components")
struct PixelComponentTests {

    @Test("Waveform tolerates empty, short, and over-long level arrays")
    func waveformBounds() {
        #expect(PixelWaveform.bars(from: [], count: 48).count == 48)
        #expect(PixelWaveform.bars(from: [], count: 48).allSatisfy { $0 == 0 })

        let flood = (0..<10_000).map { Float($0 % 100) / 100 }
        let bars = PixelWaveform.bars(from: flood, count: 48)
        #expect(bars.count == 48)
        #expect(bars.allSatisfy { (0...1).contains($0) })

        // Short input is left-padded with silence so bars stay right-aligned.
        let short = PixelWaveform.bars(from: [0.25, 1], count: 4)
        #expect(short == [0, 0, 0.25, 1])

        // A zero-width waveform must not produce a bar to divide by.
        #expect(PixelWaveform.bars(from: [0.5], count: 0).isEmpty)
    }

    @Test("Waveform sanitizes levels from the audio thread")
    func waveformClamps() {
        // Non-finite collapses to silence; finite out-of-range clamps to the rail.
        let bars = PixelWaveform.bars(from: [.nan, .infinity, -3, 7, 0.5], count: 5)
        #expect(bars == [0, 0, 0, 1, 0.5])
    }

    @Test("Determinate progress fills proportionally and clamps")
    func progressCells() {
        #expect(PixelProgress.filledCells(value: 0, cells: 24) == 0)
        #expect(PixelProgress.filledCells(value: 1, cells: 24) == 24)
        #expect(PixelProgress.filledCells(value: 0.5, cells: 24) == 12)
        #expect(PixelProgress.filledCells(value: 1.5, cells: 24) == 24)
        #expect(PixelProgress.filledCells(value: -1, cells: 24) == 0)
        #expect(PixelProgress.filledCells(value: .nan, cells: 24) == 0)
        #expect(PixelProgress.filledCells(value: 0.5, cells: 0) == 0)
    }
}
