# Maiku — Implementation Status

Last updated: 2026-07-29

## Toolchain reality check (this machine)

| Item | Value |
|---|---|
| macOS | 26.6 (25G72) |
| Architecture | arm64 (Apple Silicon) |
| Swift | 6.3.3 (swiftlang-6.3.3.1.3) |
| SDK | MacOSX26.5.sdk (also 15.4, 15) |
| Xcode | **not installed** — `xcode-select -p` → `/Library/Developer/CommandLineTools` |
| LM Studio | not running at `http://127.0.0.1:1234` at time of assessment |

### Deviation from plan §22 — build system

`plan.md` §22 mandates `xcodebuild -scheme Maiku`. **Xcode is not installed on this machine**, only
Command Line Tools, so `xcodebuild` is unavailable and no `.xcodeproj` can be built or generated.

**Decision:** build Maiku as a **Swift Package Manager** package plus a bundling script that
assembles a real `Maiku.app` (Info.plist, entitlements, ad-hoc code signature). This is required for
microphone TCC permission, which will not be granted to a bare SwiftPM executable.

- `scripts/build.sh` → `swift build` + `.app` assembly + `codesign` (exits nonzero on failure)
- `scripts/test.sh` → `swift test` (exits nonzero on failure)
- `scripts/lint.sh` → `swift format lint` when available

The CLT SDK ships SwiftUI, AppKit, AVFoundation, AVFAudio and CoreAudio, so nothing in the plan's
feature set is blocked by the missing Xcode. If Xcode is installed later, the same package opens
directly in Xcode with no source changes; the scripts gain an `xcodebuild` path at that point.

## Dependency versions (resolved, to be pinned)

| Package | Version | Purpose | License |
|---|---|---|---|
| argmaxinc/WhisperKit | 0.18.0 | local Whisper transcription | MIT |
| FluidInference/FluidAudio | 0.15.5 | VAD + speaker diarization | Apache-2.0 |
| groue/GRDB.swift | 6.29.3 | SQLite persistence + FTS5 | MIT |

Transitive: swift-transformers 1.1.9, swift-jinja 2.4.2, yyjson 0.12.0, swift-argument-parser 1.8.2,
swift-collections 1.6.0, swift-crypto 4.5.1, swift-asn1 1.7.1. Full attribution lands in
`THIRD_PARTY_NOTICES.md`.

## Milestone checklist

### Milestone 0 — Repository assessment and risk spike
- [x] Inspect every existing file (repo contained only `plan.md`)
- [x] Record build instructions and dependencies
- [x] Identify minimum macOS/Xcode requirements from actual package versions
- [x] Document dependency versions and licenses
- [x] Confirm WhisperKit + FluidAudio + GRDB compile under the CLT-only toolchain
- [x] Confirm the app can capture microphone audio
- [x] Confirm WhisperKit transcribes a short local sample
- [x] Confirm FluidAudio produces diarization output on a short sample
- [x] Confirm LM Studio connection and strict JSON output

**Exit criteria met.** Spike results below.

#### Spike results (2026-07-28)

Fixture: 15.6 s, 16 kHz mono WAV, three turns from two `say` voices
(Samantha 0–4.3 s, Daniel 4.3–11.3 s, Samantha 11.3–15.6 s).

| Path | Result |
|---|---|
| Compile | All three deps build under CLT-only SwiftPM, 37 s clean |
| Microphone | `AVAudioEngine` input tap: 48 kHz mono, 72 000 frames in 1.5 s, peak 0.0344 |
| WhisperKit `tiny.en` | 7 segments, transcript accurate apart from proper nouns ("Maker"/"dialization") |
| FluidAudio diarization | 5 turns, correctly found **2** speakers |
| GRDB FTS5 | `MATCH` + `snippet()` highlighting works |
| LM Studio | `GET /v1/models` → 9 models; strict `json_schema` decoded cleanly in 14.5 s on `qwen3.5-9b-mlx` |

Findings that change the implementation:

1. **WhisperKit segment text carries special tokens.** `segment.text` returns
   `<|startoftranscript|><|0.00|> Good morning…<|4.16|>`. The adapter must strip
   `<|…|>` tokens before anything reaches the database, and must prefer word
   timestamps over parsing those markers.
2. **Diarization boundaries drift.** The first boundary landed at 4.25 s against
   4.3 s ground truth, but the second landed at ~10.0 s against ~11.3 s, and the
   middle turn was split across both speaker labels. Plan §6.4 smoothing is not
   optional polish — it is load-bearing. Real (non-synthetic) voices should do
   better; this needs re-measuring on a genuine multi-speaker recording.
3. **Strict `json_schema` is reliable and honours `null`.** The model left
   `ownerText`/`dueDateISO8601` null rather than guessing, and cited correct
   segment IDs — the plan §7.4 hallucination controls are enforceable at the
   schema layer. Use `"type": ["string","null"]` rather than omitting keys.
4. **LM Studio autostarts.** The service was not listening until an `lms`
   command woke it. The client must treat "not running" as an expected,
   recoverable state, not an error.
5. **Capture is 48 kHz mono; the speech stack wants 16 kHz mono.** `AVAudioConverter`
   is required on the hot path.

### Milestone 1 — Thin end-to-end vertical slice — **complete**

Two parallel implementation runs were each cut off mid-flight by an API session limit; the
remaining modules (persistence, the two speech adapters, and all four screens) were then written
directly. Everything compiles, `dist/Maiku.app` builds and ad-hoc signs, and all 107 tests pass.
Nothing below is a stub, a TODO, or a fake behind a real-looking API.

| Module | State |
|---|---|
| Intelligence (LM Studio) | Client actor, models, prompt factory, strict JSON schemas, 22 tests incl. a mock server covering every error mapping |
| Audio | Capture service, CAF writer, level meter, permission, 30 tests |
| Design system | Theme, pixel components, Clawd mascot + placeholder art, asset manifest, 13 tests |
| Speech adapters | `TranscriptTokenSanitizer`, `SpeakerAlignmentService`, `WhisperKitTranscriber` (bounded rolling window + stable/unstable merge), `FluidAudioDiarizer` (file-based canonical pass; streaming is a documented no-op), 21 tests |
| Persistence | AppPaths, DatabaseManager, migrations (recordings/speakers/transcriptSegments/organizedResults + FTS5), RecordingRepository, 18 tests |
| Integration | `RecordingCoordinator` (owns the full `RecordingState` machine, wires capture → transcription → diarization → alignment → LM Studio → persistence), `AppEnvironment` |
| Screens | Library, Recording, Processing, RecordingDetail — real `NavigationStack` push flow inside `RootView`'s `NavigationSplitView` |

Bugs found and fixed while integrating, all caught by tests or by reading the actual GRDB/
AVFoundation source rather than by inspection alone:

1. Loopback detection used `Network.IPv4Address.isLoopback`, which matches only `127.0.0.1`.
   The whole `127.0.0.0/8` block is loopback (RFC 1122 §3.2.1.3), so maiku would have warned
   that transcript text was leaving the machine when it was not.
2. `AVAudioFile.read(into:)` does not guarantee draining a buffer in one call — a test assumed
   it did and failed intermittently. Fixed by looping until exhausted; the writer itself was
   already correct.
3. A single isolated `AVAudioConverter` sample-rate conversion undershoots the ideal output
   count by a one-time filter-priming latency (confirmed ~240 samples on a 4800-frame input,
   reproduced identically with mono-only input, so it is not a downmix defect). A test's lower
   bound was tighter than that legitimate floor; over a real reused-converter stream it
   self-corrects to within ~0.3% of ideal, which the multi-call test already covered.
4. `scripts/build.sh` did not copy `Resources/Clawd/` into the app bundle, so any future Clawd
   artwork would sit in the source tree but never load at runtime (`ClawdAssetManifest` resolves
   paths through `Bundle.main`, not SwiftPM's resource bundler).
5. Two Swift 6 strict-concurrency shapes recurred across both speech adapters: `accept(_:at:)`
   takes a non-`Sendable` `AVAudioPCMBuffer` no actor-isolated method can receive, and
   `updates()` is declared synchronous, which an actor can only satisfy with a `nonisolated`
   method — yet the transcriber's stream must be recreated every `startStreaming()`. Fixed by
   extracting `Sendable` data before the actor hop, and by storing the per-recording stream as
   `nonisolated(unsafe)` with a documented call-order invariant.

Verification performed:
- `./scripts/build.sh` and `./scripts/test.sh` both succeed (107/107 tests).
- Launched `dist/Maiku.app` as a live process on this machine: it initialized `AppEnvironment`
  without a `launchError`, opened its sandboxed database at
  `~/Library/Containers/com.maiku.Maiku/Data/Library/Application Support/Maiku/Maiku.sqlite`
  (confirmed via `lsof`), and the migrations ran — `sqlite3 … .tables` shows `recordings`,
  `speakers`, `transcriptSegments`, `organizedResults`, and the `recordingSearch` FTS5 tables,
  exactly matching `Migrations.swift`. Metal/RenderBox frameworks loaded, indicating SwiftUI's
  rendering pipeline initialized.
- **Not verified: the actual screens.** This machine has no attached display —
  `screencapture` fails with "could not create image from display" — so the Library screen,
  the Record button, the live waveform, and the full record → stop → process → detail flow were
  never seen rendering or exercised by hand. What's confirmed above is real (a live process
  correctly wiring its full dependency graph, including the sandbox and the database), but it is
  not the same as watching the golden path work. This needs a machine with a display before it
  can be called seen, not just built.

Known gap carried forward rather than rushed: `RecordingCoordinator.startRecording()`
constructs `AudioCaptureService()` directly instead of taking it injected, so the full
record-to-complete lifecycle isn't unit-testable without a real microphone. The individual
stages it calls (persistence, alignment, LM Studio mapping) all have coverage through their own
modules' tests.

### Milestone 2 — Reliable recording and recovery — **complete**

State machine, pause/resume, rolling writes, meter/waveform, and stable/unstable merging were
already real as of Milestone 1 (built correctly the first time rather than stubbed and revisited).
This milestone's actual new work:

- [x] `AudioCaptureService` injected behind an `AudioCapturing` protocol — the known gap flagged
      at the end of Milestone 1 — unlocking a full start-to-complete lifecycle test with fakes
- [x] Periodic disk-space checks during recording (was one-shot, at start, only)
- [x] Interrupted-recording detection on next launch
- [x] A three-way recovery screen: Recover and Process / Keep Audio Only / Delete
- [x] General processing-stage retry, not just note-generation retry
- [x] A local rotating diagnostic log, wired into every failure and lifecycle transition

12 new tests across this work, 123 total, all passing.

**Design decision — no separate recovery-manifest file.** Plan §9 asks for "a lightweight
recovery manifest for an active recording" alongside "periodic database checkpoints," suggesting
two mechanisms. `RecordingRepository.fetchInterrupted()` implements both with one: every stage
transition already saves the recording's status before doing the stage's work, and
`RecordingCoordinator` always drives a recording it starts all the way to `.complete` or
`.failed` before returning control — so a row found at launch in any other status could only be
interrupted, never abandoned by ordinary control flow. A second, parallel manifest file would
duplicate this and could itself drift out of sync with the database it's describing. If a
concrete need for a manifest distinct from the DB row surfaces later (e.g. surviving database
corruption specifically), add it then — this is documented as a deliberate simplification, not an
oversight.

**Design decision — recovery restarts at `finalizingAudio`, not the exact interrupted stage.**
Every stage replaces its own output wholesale (`replaceSegments`, `upsertSpeakers`,
`saveOrganizedResult`), so re-running the whole finalization pipeline from the top is correct
regardless of which stage was interrupted — just capable of redoing work a smarter per-stage
resume would skip (e.g. re-transcribing when only note generation had actually failed). Simpler,
still correct, and reuses the same code path for "recover an interrupted recording," "retry a
`.failed` recording from the detail screen," and "retry organization only" (the narrower,
existing action for a recording that completed but whose notes failed).

**Verification.** `./scripts/build.sh` and `./scripts/test.sh` both succeed. The recovery
scenario itself — kill the process mid-recording, relaunch, see the recovery screen, choose an
action — was verified through `RecordingCoordinatorTests`/`RecoveryServiceTests` using fakes that
reproduce exactly that shape (a recording persisted in a non-terminal status with a real audio
file on disk, recovered via `recoverAndProcess`), not by literally killing the running GUI app
and watching it happen — this machine still has no attached display, the same limitation noted
under Milestone 1. The underlying logic is tested thoroughly; the actual screen has not been
seen.

### Milestone 3 — Final diarization and synchronized transcript — **complete**

Final diarization, speaker/word alignment, smoothing, and speaker rename were already real as of
Milestone 1. This milestone's actual new work:

- [x] `AudioPlaybackService` — an actor wrapping `AVAudioPlayer`, since it isn't documented
      thread-safe; polls position every 100ms rather than gating on `isPlaying`, so the exact
      moment playback ends at end-of-file is still reported
- [x] A persistent compact audio player (play/pause, scrubber, speed) shown across every tab in
      `RecordingDetailView`
- [x] Click-to-seek: clicking a transcript segment's timestamp or a quote seeks and starts
      playback, not merely cues a paused player
- [x] Current-segment highlighting during playback
- [x] Inline transcript editing, marking the edited segment `.userEdited` so a future
      reprocess preserves it — commits on focus loss, not only `.onSubmit`, since a
      vertical-axis `TextField` lets Return insert a newline instead of submitting on macOS
- [x] Real streaming provisional speaker labels, replacing the Milestone 1 no-op

14 new tests (5 pure-logic, 9 for `AudioPlaybackService`) plus one opt-in real-model integration
test, 137 total, all passing.

**Design decision — streaming diarization reuses the offline pipeline instead of adopting
FluidAudio's separate streaming protocol.** FluidAudio ships two APIs: `DiarizerManager`
(what the final, canonical pass already uses) and a distinct `Diarizer` protocol implemented by
Sortformer/LS-EEND, built for true frame-by-frame streaming. Adopting the latter for live
provisional labels would mean a second model download, a different API entirely, and — worse —
live speaker numbering with no guaranteed relationship to the file-based pass's numbering for the
*same* recording. Instead, streaming periodically re-runs `performCompleteDiarization` — the
identical call `diarizeFile(at:)` makes — over a bounded, trimmed rolling window (6s flush
interval, 30s cap, the same shape as `WhisperKitTranscriber`'s window). This works only because
`DiarizerManager.speakerManager` persists across repeated calls on the *same* instance, so a
voice recognised in one flush keeps its label in the next — an empirical claim, not something
inferable from the type signatures alone, and it is verified for real: `MAIKU_INTEGRATION_TESTS=1`
gates a test that feeds a checked-in four-turn two-speaker fixture through actual streaming
against the real downloaded models and confirms the final turn's label already appeared in the
first flush. It passed on this machine.

**Real bug found and fixed while reasoning through that design, not by inspection.**
`speakerManager` was never reset between diarization sessions on the shared, long-lived
`FluidAudioDiarizer` instance `AppEnvironment` constructs once for the app's lifetime. Recording
B's canonical final pass could inherit speaker state from recording A's final pass, or from the
same recording's own live session — either way biasing what plan §6.4 requires to be
authoritative. Fixed by resetting to a fresh `SpeakerManager()` at the top of both
`startStreaming()` and `diarizeFile(at:)`.

**Verification.** `./scripts/build.sh` and `./scripts/test.sh` succeed, including the opt-in
integration test run once with the real models. As with Milestones 1 and 2, the actual screens —
the player controls, the highlighting, the live speaker badges — have not been seen rendering on
this machine; see Known Limitations.

### Milestone 4 — Complete organization pipeline — **complete**

Strict JSON schemas, source segment references, and the invalid-output repair retry all already
existed from Milestone 1 — `OrganizationSchema`, `PromptFactory`, and `LMStudioClient`'s
one-repair-attempt-then-report behavior were built correctly the first time. This milestone's
actual new work:

- [x] `TranscriptChunker` — segment-boundary-respecting, silence-gap-preferring, configurable
      character budget, overlap between chunks
- [x] The reduce pass: `PromptFactory.reduce`, `OrganizationSchema` reused unchanged (the output
      shape doesn't change), `LMStudioClient.reduceChunkSummaries`
- [x] `OutputValidator` — a second, independent check after decoding: every sourced claim's
      segment ids verified against the real transcript, discarded if none are valid; every
      quote's text verified against its cited segment after whitespace normalization; a
      hallucinated owner/speaker reference nulled rather than discarding the whole item
- [x] `OrganizationPipeline` — the orchestrator: chunk → map → reduce → validate, with a
      single-chunk shortcut so a short recording never pays for a wasted extra round trip
- [x] Retry organization independently of transcription — already existed from Milestone 1/2
      (`retryOrganization(for:)`), now routed through the same pipeline
- [x] Editable organized notes — the milestone's own exit criteria names this explicitly; the
      Notes tab was still read-only, now each section is inline-editable

29 new tests (10 chunker, 16 validator, 3 pipeline), 166 total, all passing.

**Design decision — `OrganizationPipeline` sequences chunks, never runs them concurrently.**
A single local LM Studio server processes one inference at a time regardless of how many
requests arrive concurrently; overlapping requests would only queue behind each other while
making a failure harder to attribute to a specific chunk. Sequential is simpler and costs
nothing a local server could actually have delivered anyway.

**Verification.** `./scripts/build.sh` and `./scripts/test.sh` both succeed. The multi-chunk
test confirms the pipeline fires exactly the expected number of LM Studio requests (map count
plus one reduce) against a stub server — the closest available proof the orchestration logic
is correct, short of a long real recording through a live LM Studio instance. As with every
milestone so far, the actual screens have not been seen rendering on this machine; see Known
Limitations.

### Milestone 5 — Library, search, export, and settings — **complete**

Recording library and processing status cards already existed from Milestone 1
(`LibraryView`, `ProcessingView`, `StatusBadge`); FTS5 search existed at the repository layer
(`RecordingRepository.search(_:)`) with no UI reaching it. Trash's repository plumbing
(`trash(id:)`, `deletePermanently(id:)`, the `trashedAt` column) existed too, but nothing in the
app ever called it — this was the first milestone where trashing was reachable from any screen.
This milestone's actual new work:

- [x] Settings persistence — a singleton `appSettings` row (migration `v2`), `AppSettings`,
      `SettingsStore`, and `KeychainTokenStore` for the LM Studio token (plan §12: Keychain, never
      SQLite)
- [x] `AppEnvironment` now loads persisted settings + the Keychain token before constructing
      `LMStudioClient`, and every `prepareModels()` call site reads the configured speech model and
      live-diarization toggle instead of a hardcoded `tiny.en`/always-on default
- [x] `RecordingCoordinator` gates the *streaming* diarizer calls behind the live-diarization
      toggle; the file-based final pass after stop always runs regardless
- [x] `SpeechModelLibrary` — Whisper model discovery (`WhisperKit.recommendedModels()`), download,
      and deletion, matching a plain variant name against WhisperKit's on-disk repo folder naming
- [x] Settings screen — all six plan §10.7 sections: Audio (default input device), Transcription
      (language, live-diarization toggle, model list with download/delete), LM Studio (base URL,
      token, connection test, model picker, timeout), Storage (data directory size, audio
      retention), Appearance (reduced motion/sound/CRT toggles), Privacy and diagnostics
      (redacted-by-default diagnostics export)
- [x] `search(_:filters:)` extended with a `SearchFilters` struct — status, speaker name, tag,
      date range — joined against `recordings`; filters work standalone so a screen can browse by
      filter with no text query. `fetchAllTags()`/`fetchAllSpeakerNames()` populate filter pickers.
      Trashed recordings are now excluded from ordinary search by default, matching
      `fetchAll(includeTrashed:)`'s existing convention
- [x] Search screen — text query plus every filter, snippet-highlighted results
- [x] Tags screen — distinct tags with per-tag recording counts, tapping one shows matching
      recordings
- [x] `RecordingRepository.restore(id:)` and `fetchTrashed()`; a Move to Trash/Restore action on
      `RecordingDetailView`; a Trash screen with Restore and confirmed Delete Permanently (through
      `RecoveryService.deletePermanently`, so the audio directory goes with it)
- [x] `RecordingExporter` (`Sources/MaikuKit/Export/`) — all five plan §11.2 formats from one
      `RecordingExportContext` snapshot: Markdown, plain text, JSON (a stable export schema, not
      the internal DB shape), and SRT/VTT subtitles. Wired into `RecordingDetailView` as an Export
      menu, writing through `NSSavePanel`
- [x] `Docs/ARCHITECTURE.md` — deferred three times waiting for the module shape to settle; written
      now that it has
- [x] A short recording-consent reminder on the Recording screen (plan §12's other non-negotiable
      that had no home until now)

18 new tests across this work (settings store, Keychain store, live-diarization toggle,
`SpeechModelLibrary`'s folder-matching, search filters, `fetchAllTags`/`fetchAllSpeakerNames`,
restore/`fetchTrashed`, the exporter's five formats), 191 total, all passing.

**Design decision — search filters by speaker *name*, not speaker id.** Plan §12 forbids
persisting a reusable identity across recordings, so a `Speaker` row's id has no meaning outside
the one recording it came from — the *only* thing that ever means "the same person" across two
recordings is a name a user typed themselves. `SearchFilters.speakerName` matches `customName`
exactly; an unrenamed "Speaker 1" is not filterable across recordings by design, not omission.

**Design decision — tag filtering uses `json_each` against the organized-result JSON, not FTS5.**
A tag is an identifier, not prose — matching it through FTS5's tokenizer risks a partial/stemmed
match ("launch" matching "launching"). `json_each(organizedResults.json, '$.tags')` inside an
`EXISTS` subquery gives an exact match instead, reusing SQLite's bundled JSON1 extension rather
than adding a normalized tags table for a single equality check.

**Design decision — `restore(id:)` infers the prior status rather than storing it.**
`trash(id:)` overwrites `status` to `.trashed` with no separate column for what it was before.
`errorMessage` is already set only alongside `.failed` and cleared whenever a stage completes, so
it is the one already-persisted signal available: `restore(id:)` returns to `.failed` if that is
set, `.complete` otherwise. Adding a dedicated `previousStatus` column was considered and rejected
as one more piece of state to keep in sync for a case the existing data already answers correctly.

**Design decision — no explicit input-device picker.** Plan §10.7 offers "Microphone selection
**or** current default device" as alternatives. Routing `AVAudioEngine` to a specific non-default
input device is a capture-layer change, not a Settings-screen one — Settings shows the current
system default input device's name, read-only, which the plan's own wording allows.

**Verification.** `./scripts/build.sh` and `./scripts/test.sh` both succeed (191/191). The
`json_each` tag-filter query and the Whisper model repo-folder-naming heuristic were both
verified against genuine risk of being wrong (an untested SQLite extension availability
assumption; a folder-naming convention this codebase doesn't control) rather than assumed correct
by construction — see `RecordingRepositoryTests.searchFiltersNarrowResults`/`fetchAllTagsCounts…`
and `SpeechModelLibraryTests`. As with every milestone so far, the actual screens — Settings,
Search, Tags, Trash, and the new Export menu — have not been seen rendering on this machine; see
Known Limitations.

### Milestone 6 — Pixel polish, accessibility, and release readiness — **complete**

The 8-bit design system's tokens, pixel components, and Clawd state machine all already existed
from Milestone 1 (`Theme.swift`, `PixelButton`/`Panel`/`Progress`/`Waveform`, `ClawdView`). This
milestone's actual new work:

- [x] The first authorized Clawd artwork — an 8-frame `listening` animation supplied by the
      maintainer — wired into `ClawdAssetManifest` at its own frame count and timing (8 frames,
      110ms) rather than forcing it into the plan's original 4-frame sketch
- [x] A real bug this exposed, fixed: `ClawdArtwork.isInstalled` was one app-wide flag, so
      installing any state's art would have hidden the "Placeholder art" badge on every other
      state too, including the eight that still have none. Replaced with `isFullyInstalled(_:)`,
      cached per state's own frame list, with an injectable resolver so the per-state
      independence is unit-tested directly rather than only inferred from reading the code
- [x] Reduced Motion, CRT effects, and sound effects — all three were persisted in `AppSettings`
      since Milestone 5 but never consumed anywhere. `EffectsGating` (pure, unit-tested
      functions) decides all three; a writable `\.effectiveReduceMotion` environment key carries
      a user override past SwiftUI's own get-only `\.accessibilityReduceMotion`; `CRTOverlay`
      draws static scan lines and a vignette; `SoundEffects` gates `NSSound` system cues through
      `AppEnvironment.playSound(_:)`. `AppEnvironment` is now `@Observable` with a
      `currentSettings` mirror so all three take effect immediately when changed, not at next
      launch
- [x] An accessibility audit against plan §13.2, not just a reading of the code: computed real
      WCAG contrast ratios for every `Theme.Colors` text/status pair (`WCAGContrast`) and found
      two real failures — light-theme `warning` and `success`, both used at `.caption` size,
      measured 4.22–4.28:1 against their surface, under AA's 4.5:1. Darkened both ~10%, same hue,
      to clear it with margin, and locked the audit in as a regression test. Also found and fixed
      three real VoiceOver gaps (an unlabeled selection checkmark, a warning icon and message
      reading as two disconnected elements, a decorative chevron read as noise on top of a
      button's own semantics), and confirmed there are no `onTapGesture`-only controls anywhere —
      everything interactive already goes through `Button`
- [x] An app icon (`Resources/AppIcon.icns`) — a pixel-styled cream/orange waveform glyph,
      generated with a small CoreGraphics script and `sips`/`iconutil` rather than hand-drawn,
      deliberately not using Clawd (the icon is the app's most visible surface, and only one
      mascot state has authorized art so far)
- [x] An About screen (`AboutView`, a Settings sheet) stating plainly that maiku is independent
      and not affiliated with Anthropic, and that any Clawd artwork shown was supplied by the
      maintainer under their own authorization (plan §14)
- [x] `Docs/MANUAL_ACCEPTANCE.md` — plan §17.4's thirteen scenarios, each cross-referenced against
      which automated tests already cover the logic versus what would be exercised for real for
      the first time
- [x] `Docs/DISTRIBUTION.md` — the signing and notarization runbook for whoever has Developer ID
      credentials later, so distributing a real build doesn't require re-deriving the process

9 new tests across this work (Clawd manifest regression + `isFullyInstalled` independence,
`EffectsGating`, `GatedSoundPlayer`, `WCAGContrast` formula sanity + both themes' audited pairs),
200 total, all passing.

**Design decision — `listening` ships 8 frames, not the 4 plan §14's suggested manifest
sketched.** The plan's own frame list was a starting sketch for a placeholder-first
implementation, not a fixed contract; the first real art actually supplied came as an 8-frame
loop with its own metadata (110ms/frame), and forcing it down to 4 frames or inventing 4
durations not present in the source would have been the less honest choice.

**Design decision — a second, writable `\.effectiveReduceMotion` environment key, not an override
of `\.accessibilityReduceMotion` directly.** SwiftUI's own key is get-only from outside the
system — there is no supported way to make `.environment(\.accessibilityReduceMotion, _)`
override it for a subtree (confirmed by the compiler, not assumed). `ClawdView`/`PixelProgress`
now read the new key instead, set once in `RootView` from `EffectsGating.effectiveReduceMotion`.

**Design decision — sound effects use plain `NSSound(named:)` system sounds, not bundled audio
assets.** Every cue (`Pop`, `Bottle`, `Glass`, `Basso`) ships with macOS; there is nothing to
author, license, or bundle for a handful of short UI chimes, and the moments they fire from
(recording start/stop, processing complete, error) are exactly what plan §13.2's "sound effects
toggle" was describing.

**Verification.** `./scripts/build.sh` and `./scripts/test.sh` both succeed (200/200), and the
app icon was confirmed actually present at `dist/Maiku.app/Contents/Resources/AppIcon.icns` after
a real build, not just referenced in `Info.plist`. As with every milestone so far, the actual
screens — the new About sheet, the CRT overlay, the real listening-state animation — have not
been seen rendering on this machine; see Known Limitations.

## Known limitations

- **No Xcode on this machine.** No `.xcodeproj`, no `xcodebuild`, and no XCUITest runner. Plan
  §17.3 UI tests are blocked until Xcode is installed; the underlying view models get unit
  coverage instead. Unit tests themselves work fine — `swift-testing` ships inside the Command
  Line Tools, but SwiftPM only wires its search paths when driven by Xcode, so `scripts/test.sh`
  adds `-F …/Library/Developer/Frameworks` and an rpath to
  `…/Library/Developer/usr/lib` (for `lib_TestingInterop.dylib`). Without those, `swift test`
  fails with "no such module 'Testing'" and then a dlopen error.
- **Only one Clawd state has authorized artwork.** `listening` was supplied by the maintainer as
  of Milestone 6; the other eight states still render the clearly labelled placeholder per plan
  §14's asset rule, against the same documented filenames, until art for them is supplied too.
- Notarization and Developer ID signing are unavailable (no credentials, no Xcode). The build
  script ad-hoc signs for local development only — see `Docs/DISTRIBUTION.md` for the exact
  signing and notarization steps to run once credentials exist.
- Notarization and Developer ID signing are unavailable (no credentials). The build script
  ad-hoc signs for local development only — see `Docs/DISTRIBUTION.md` for the exact signing and
  notarization steps to run once credentials exist.

### Visual verification (2026-07-29)

A machine with an attached display and microphone became available for the first time since
Milestone 1. Ran the full golden path by hand (`./scripts/build.sh`, launch `dist/Maiku.app`,
drive it via macOS accessibility scripting): Library → Record (real TCC microphone permission
prompt, granted once and correctly not re-prompted on a second recording) → live recording screen
(real waveform, real `WhisperKit` streaming transcript, the consent reminder) → Stop → Processing
(real staged pipeline through the LM Studio organize step) → Detail screen, auto-navigated,
COMPLETE status, working audio player and Overview/Notes/Transcript/Action Items tabs. Also
confirmed on a recording with real speech, not just silence: correct transcription, a real
speaker identified, and a coherent LM Studio summary/key-takeaways. Every screen renders as
designed; nothing above was previously more than compiled-and-unit-tested.

**Real bug found and fixed.** Switching from one recording's detail screen to another's could
show the *previous* recording's audio duration in the player instead of the new one's — e.g. a
0:16 recording displayed as "1:15" (an earlier recording's length). Root cause:
`RecordingDetailView`'s `@State private var playbackState` is never reset, and since
`.navigationDestination(for: LibraryRoute.self)` pushes `RecordingDetailView(recordingID:)` with
no `.id(recordingID)`, SwiftUI can reuse the same `@State` storage across two different
recordings' detail screens — so the old recording's last known duration keeps rendering until a
fresh value arrives, however long that takes. Fixed by resetting `playbackState` to a neutral
value at the top of `loadAudio()`, the same fix-up shape already used for `recording`/`segments`/
`speakers`/`organized` in that file. `AudioPlaybackService.stop()` was also changed to publish a
neutral `PlaybackState` (it previously did nothing observable), closing a related edge case where
a value already sitting in the state stream's one-slot buffer could reach a newly (re)started
listener. No existing test covered either path — this class of bug (view-identity reuse across
push-navigation, not caught by any unit test that only ever constructs one `RecordingDetailView`
per test) only surfaces under real, hands-on navigation.

## Next task

All six milestones plan.md defines (§16, Milestones 0–6) are complete, and the golden path is now
visually confirmed end-to-end. What remains:

1. **`Docs/MANUAL_ACCEPTANCE.md`'s thirteen scenarios** — now runnable with today's display access,
   not yet executed.
2. **Eight of nine Clawd states still have no authorized artwork** — only `listening` does.
   `Resources/Clawd/README.md` has the exact filenames and format each remaining state needs.
3. **Signing and notarization are blocked on credentials** (`Docs/DISTRIBUTION.md` has the exact
   steps to run once a Developer ID certificate exists).

No further code changes are expected to be needed to reach plan.md's stated scope — everything
above is either hands-on verification or waiting on an external resource (artwork or a paid
developer account) rather than unwritten logic.
