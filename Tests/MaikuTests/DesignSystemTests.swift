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
                "clawd_paused_01.png",
                "clawd_paused_02.png",
                "clawd_paused_03.png",
                "clawd_paused_04.png",
                "clawd_paused_05.png",
                "clawd_paused_06.png",
                "clawd_transcribing_01.png",
                "clawd_transcribing_02.png",
                "clawd_transcribing_03.png",
                "clawd_transcribing_04.png",
                "clawd_transcribing_05.png",
                "clawd_transcribing_06.png",
                "clawd_transcribing_07.png",
                "clawd_transcribing_08.png",
                "clawd_organizing_01.png",
                "clawd_organizing_02.png",
                "clawd_organizing_03.png",
                "clawd_organizing_04.png",
                "clawd_organizing_05.png",
                "clawd_organizing_06.png",
                "clawd_organizing_07.png",
                "clawd_organizing_08.png",
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

@Suite("Effects gating")
struct EffectsGatingTests {

    @Test("A user override wins over the system Reduce Motion setting, in both directions")
    func reduceMotionOverrideWins() {
        #expect(EffectsGating.effectiveReduceMotion(override: true, systemReduceMotion: false))
        #expect(!EffectsGating.effectiveReduceMotion(override: false, systemReduceMotion: true))
    }

    @Test("With no override, the system Reduce Motion setting passes through")
    func reduceMotionFallsBackToSystem() {
        #expect(EffectsGating.effectiveReduceMotion(override: nil, systemReduceMotion: true))
        #expect(!EffectsGating.effectiveReduceMotion(override: nil, systemReduceMotion: false))
    }

    @Test("CRT effects require both the toggle on and Reduce Motion off")
    func crtEffectRequiresBoth() {
        #expect(EffectsGating.showsCRTEffect(crtEffectsEnabled: true, reduceMotion: false))
        #expect(!EffectsGating.showsCRTEffect(crtEffectsEnabled: false, reduceMotion: false))
        #expect(!EffectsGating.showsCRTEffect(crtEffectsEnabled: true, reduceMotion: true))
        #expect(!EffectsGating.showsCRTEffect(crtEffectsEnabled: false, reduceMotion: true))
    }
}

@Suite("Theme contrast")
struct ThemeContrastTests {

    @Test("The contrast formula is sane at known reference points")
    func formulaSanityCheck() {
        #expect(abs(WCAGContrast.ratio(0x00_0000, 0xFF_FFFF) - 21.0) < 0.01)
        #expect(WCAGContrast.ratio(0xFF_FFFF, 0xFF_FFFF) == 1.0)
    }

    /// Mirrors `Theme.Colors`' literal hex values — Theme.swift stores a
    /// resolved SwiftUI `Color`, not a hex constant, so there is no way to
    /// read them back live here. Kept in sync by hand, the same way
    /// `ClawdManifestTests.fileNamesMatchSpec` asserts its filename list
    /// literally rather than derives it: this is meant to fail loudly the
    /// next time someone changes a color without re-running the audit.
    @Test("Light theme text and status colors meet WCAG AA (4.5:1) against their surface")
    func lightThemeMeetsAA() {
        let pairs: [(name: String, foreground: UInt32, background: UInt32)] = [
            ("textPrimary/surface", 0x2B_1E14, 0xF4_EBDC),
            ("textSecondary/surface", 0x6B_5844, 0xF4_EBDC),
            ("onAccent/accent", 0x1F_1409, 0xE0_7A17),
            ("onDanger/destructive", 0xFF_F3E6, 0xC4_2B1C),
            ("warning/surface", 0x7C_5F09, 0xF4_EBDC),
            ("success/surface", 0x38_7034, 0xF4_EBDC),
        ]
        for pair in pairs {
            let measured = WCAGContrast.ratio(pair.foreground, pair.background)
            #expect(measured >= 4.5, "\(pair.name) measured \(measured), below WCAG AA")
        }
    }

    @Test("Dark theme text and status colors meet WCAG AA (4.5:1) against their surface")
    func darkThemeMeetsAA() {
        let pairs: [(name: String, foreground: UInt32, background: UInt32)] = [
            ("textPrimary/surface", 0xF2_E7D5, 0x17_110C),
            ("textSecondary/surface", 0xB7_A489, 0x17_110C),
            ("onAccent/accent", 0x1B_1109, 0xFF_9A3C),
            ("onDanger/destructive", 0x1B_1109, 0xFF_5A48),
            ("warning/surface", 0xE8_C25A, 0x17_110C),
            ("success/surface", 0x6F_BF63, 0x17_110C),
        ]
        for pair in pairs {
            let measured = WCAGContrast.ratio(pair.foreground, pair.background)
            #expect(measured >= 4.5, "\(pair.name) measured \(measured), below WCAG AA")
        }
    }
}

@Suite("Sound effects")
struct SoundEffectsTests {

    private final class SpyPlayer: SoundPlaying {
        private(set) var played: [SoundCue] = []
        func play(_ cue: SoundCue) { played.append(cue) }
    }

    @Test("An enabled gate forwards the cue to the underlying player")
    func enabledGateForwardsCue() {
        let spy = SpyPlayer()
        let gated = GatedSoundPlayer(player: spy, isEnabled: { true })
        gated.play(.recordingStarted)
        #expect(spy.played == [.recordingStarted])
    }

    @Test("A disabled gate never reaches the underlying player")
    func disabledGateIsANoOp() {
        let spy = SpyPlayer()
        let gated = GatedSoundPlayer(player: spy, isEnabled: { false })
        gated.play(.error)
        #expect(spy.played.isEmpty)
    }
}
