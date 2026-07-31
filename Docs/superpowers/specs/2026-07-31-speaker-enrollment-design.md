# Speaker enrollment — design

## Problem

Diarization ("who spoke when") currently resets to a blank slate at the start
of every recording (`FluidAudioDiarizer.startStreaming()` /
`diarizeFile(at:)` both do `manager.speakerManager = SpeakerManager()`), by
deliberate v1 design — see the comment on `Speaker.swift`: "Version 1
deliberately does not persist reusable voiceprints across recordings." So
"Speaker 1" in one recording has no relationship to "Speaker 1" in another;
the user has to rename speakers by hand (`SpeakerRenameRow` in
`RecordingDetailView`) every single time, even for the same recurring people.

This adds a one-time voice enrollment flow — a person reads a few phrases,
the app remembers their voice — so recurring participants get auto-labeled
with their real name in *future* recordings without manual renaming.

## Scope

- Enroll any number of named people (not just "the app's owner").
- Enrollment only affects diarization on recordings made *after* enrollling
  — no retroactive re-labeling of existing recordings.
- Enrollment happens through a dedicated flow in Settings only. No shortcut
  to enroll someone from an already-diarized past recording in this pass.
- Editing (rename, re-record/replace voice sample, delete) is in scope.

## Feasibility (already verified against the vendored FluidAudio package)

FluidAudio's `SpeakerManager` already has everything needed for exactly this:

- `DiarizerManager.extractSpeakerEmbedding(from: [Float]) throws -> [Float]`
  — turns a clip of one person's speech into a 256-dimensional embedding.
  Assumes the whole clip is one speaker (matches "read these phrases aloud").
- `FluidAudio.Speaker { id, name, currentEmbedding, isPermanent, ... }` — a
  named, embeddable, persistable speaker profile type.
- `SpeakerManager.initializeKnownSpeakers(_ speakers: [Speaker], mode:,
  preserveIfPermanent:)` — seeds a `SpeakerManager` with known speakers
  before diarization runs, so a matching voice gets labeled with that
  speaker's `id` directly instead of an ad-hoc per-recording cluster id.

None of this is used anywhere in maiku today. This design wires it in.

## Architecture

```
Settings → People section
  ├─ list of EnrolledSpeaker (name, enrolled date)
  ├─ "Add Person" → enrollment sheet → SpeakerEnrollmentCoordinator
  │     1. name field
  │     2. read-phrases screen (PixelWaveform live level, ≥10s gate)
  │     → diarizer.extractEmbedding(from: capturedSamples)
  │     → EnrolledSpeakerRepository.save(...)
  ├─ rename (inline text field, same pattern as SpeakerRenameRow)
  ├─ "Re-record voice" → same sheet, replaces the existing embedding
  └─ "Delete" → .confirmationDialog → EnrolledSpeakerRepository.delete(...)

RecordingCoordinator.startRecording()
  → fetch roster from EnrolledSpeakerRepository
  → diarizer.setKnownSpeakers(roster)      // new
  → diarizer.startStreaming()               // unchanged call, now seeded

RecordingCoordinator's file-based final pass
  → diarizer.diarizeFile(at:)               // unchanged call, now seeded
    (setKnownSpeakers from the same startRecording() call still applies —
    same actor instance for the lifetime of one recording)

FluidAudioDiarizer.startStreaming() / diarizeFile(at:)
  → manager.speakerManager = SpeakerManager()               // still resets
  → speakerManager.initializeKnownSpeakers(knownSpeakers)    // then reseeds
    (fresh per recording — no cross-recording ad-hoc speaker leakage;
    only the persisted, enrolled roster carries over, by design)

RecordingCoordinator.makeSpeakers(for:recordingID:)
  → when a diarized label matches an enrolled speaker's id,
    pre-fill Speaker.customName with that person's name
```

## Data model

New model, `Sources/MaikuKit/Core/Models/EnrolledSpeaker.swift`:

```swift
public struct EnrolledSpeaker: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var embedding: [Float]   // 256-dim, L2-normalized (FluidAudio's format)
    public var createdAt: Date
    public var updatedAt: Date
}
```

New migration `v4` in `Migrations.swift`:

```swift
try db.create(table: "enrolledSpeakers") { t in
    t.column("id", .text).primaryKey()
    t.column("name", .text).notNull()
    t.column("embeddingJSON", .text).notNull()
    t.column("createdAt", .datetime).notNull()
    t.column("updatedAt", .datetime).notNull()
}
```

`embeddingJSON` stores `JSONEncoder().encode([Float])` as text — same
"blob of JSON in a text column" shape `organizedResults.json` already uses
for structured, non-relational data. No new binary-encoding code needed.

New repository, `Sources/MaikuKit/Persistence/Repositories/EnrolledSpeakerRepository.swift`
(mirrors `SettingsStore`'s shape — a thin GRDB wrapper):

```swift
public actor EnrolledSpeakerRepository {
    public init(dbManager: DatabaseManager)
    public func save(_ speaker: EnrolledSpeaker) async throws
    public func fetchAll() async throws -> [EnrolledSpeaker]
    public func rename(id: UUID, to name: String) async throws
    public func updateEmbedding(id: UUID, embedding: [Float]) async throws
    public func delete(id: UUID) async throws
}
```

## FluidAudioDiarizer / SpeakerDiarizing changes

Two new methods on the `SpeakerDiarizing` protocol (so `RecordingCoordinator`
keeps depending only on the protocol, and the existing `FakeDiarizer` test
double in `RecordingCoordinatorTests.swift` stays the pattern for testing —
gains two trivial stub implementations):

```swift
public protocol SpeakerDiarizing: Sendable {
    func prepare() async throws
    func setKnownSpeakers(_ speakers: [EnrolledSpeaker]) async   // new
    func extractEmbedding(from samples: [Float]) async throws -> [Float]  // new
    func startStreaming() async throws
    func accept(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) async throws
    func updates() -> AsyncThrowingStream<DiarizationUpdate, Error>
    func finishStreaming() async throws -> DiarizationResult
    func diarizeFile(at url: URL) async throws -> DiarizationResult
}
```

`FluidAudioDiarizer`:
- `setKnownSpeakers` stores `[EnrolledSpeaker]` mapped to `[FluidAudio.Speaker]`
  (`Speaker(id: enrolled.id.uuidString, name: enrolled.name, currentEmbedding:
  enrolled.embedding, isPermanent: true)`) in a new actor property.
- `startStreaming()` / `diarizeFile(at:)`: after the existing
  `manager.speakerManager = SpeakerManager()` reset, add
  `speakerManager.initializeKnownSpeakers(knownSpeakers, mode: .skip,
  preserveIfPermanent: true)` when non-empty.
- `extractEmbedding(from:)` wraps `manager.extractSpeakerEmbedding(from:)`,
  throwing `MaikuError.diarizationFailed` on failure or if `prepare()`
  hasn't run — matching every other error path in this file.

One shared `FluidAudioDiarizer` instance is used for both the recording
coordinator and the new enrollment coordinator (see below) — `AppEnvironment`
constructs it once and passes it to both. This is safe: `extractEmbedding`
and `setKnownSpeakers` don't touch the rolling-window streaming state
(`windowSamples`, `emittedTurns`, etc.), and enrollment/recording are
mutually exclusive user flows.

## RecordingCoordinator changes

- New dependency: `enrolledSpeakerRepository: EnrolledSpeakerRepository`,
  added to the initializer alongside the existing repositories.
- In `startRecording()`, right before `diarizer.startStreaming()`: fetch the
  roster and call `await diarizer.setKnownSpeakers(roster)`. Fetched fresh
  per recording (not cached at init) so a person enrolled mid-session is
  recognized by the very next recording, matching the existing pattern
  `prepareModels`/`startRecording` already use for reading current settings
  live rather than caching them at construction.
- `makeSpeakers(for:recordingID:)` gains a `knownNames: [String: String]`
  parameter (diarizer speaker id → enrolled name, built from the same roster
  fetch) and pre-fills `customName: knownNames[label]` when constructing each
  `Speaker`. A recognized person's name is correct from the moment
  processing finishes — no manual rename step.

## Enrollment coordinator (new)

`Sources/MaikuKit/Processing/SpeakerEnrollmentCoordinator.swift` — mirrors
`RecordingCoordinator`'s shape (same `AudioCapturing` abstraction, same
metrics-stream consumption pattern) but far simpler: no transcription, no
LM Studio, no processing state machine.

```swift
@MainActor
@Observable
public final class SpeakerEnrollmentCoordinator {
    public private(set) var metrics = CaptureMetrics(elapsed: 0, level: 0, peak: 0, waveform: [])
    public private(set) var isRecording = false
    public private(set) var lastError: MaikuError?

    public init(
        diarizer: any SpeakerDiarizing, repository: EnrolledSpeakerRepository,
        makeAudioCapture: @escaping @Sendable (String?) -> any AudioCapturing = {
            AudioCaptureService(inputDeviceUID: $0)
        })

    public func fetchRoster() async throws -> [EnrolledSpeaker]
    public func startCapture(inputDeviceUID: String? = nil) async throws
    // `metrics.elapsed` (already tracked) drives the ≥10s "Done" gate directly —
    // no separate property needed.
    public func finishCapture(name: String, replacing existingID: UUID? = nil) async throws -> EnrolledSpeaker
    public func cancelCapture() async
    public func rename(_ speaker: EnrolledSpeaker, to name: String) async throws
    public func delete(_ speaker: EnrolledSpeaker) async throws
}
```

`startCapture` writes to a scratch file under
`FileManager.default.temporaryDirectory` (required by
`AudioCapturing.start(writingTo:)`) purely because the API needs a
destination; the file is deleted once capture stops regardless of outcome —
only the derived embedding is ever persisted, not the voice sample itself.
Samples for embedding extraction come from the same `speechAudio` 16kHz-mono
stream `RecordingCoordinator` already consumes, accumulated in memory.

`AppEnvironment` wiring: construct `EnrolledSpeakerRepository` alongside the
other repositories, hoist the single `FluidAudioDiarizer()` into a local
`let diarizer`, pass it to both `RecordingCoordinator(diarizer: diarizer,
enrolledSpeakerRepository: enrolledSpeakerRepository, ...)` and
`SpeakerEnrollmentCoordinator(diarizer: diarizer, repository:
enrolledSpeakerRepository)`, exposing the latter as a new
`public let speakerEnrollment: SpeakerEnrollmentCoordinator`.

## UI

New file `Sources/Maiku/Features/Settings/PeopleSection.swift`, added to
`SettingsView` as its own section, following the existing section pattern
(`speechModelRow`-style rows inside a `PixelPanel`, `.font(theme.font.body)`
cascade, `ErrorBanner` for failures).

- Each enrolled person is a row: name (inline-editable `TextField`, same
  pattern as `SpeakerRenameRow`) + a native `Menu` with "Re-record voice" and
  "Delete."
- "Add Person" button opens `.sheet` (matching `AboutView`'s existing modal
  precedent):
  1. Name field, "Continue."
  2. Phrase-reading screen: capture starts automatically the moment this step
     appears (`.task { try? await coordinator.startCapture() }`) — no extra
     "start recording" tap, since the whole point is just reading the
     sentences aloud. 5–6 fixed sentences shown as static text
     (phonetically varied, not semantically meaningful — e.g. "The quick
     brown fox jumps over the lazy dog," "Please call Stella and ask her to
     bring these things," "A large size in stockings is hard to sell,"
     "Peter Parker's picture perfectly portrays a pleasant person," "We need
     a small plastic snake and a big toy frog for the kids."), a
     `PixelWaveform(levels: metrics.waveform)` live indicator (same component
     `RecordingView` already uses), elapsed time, and "Done" — disabled until
     `metrics.elapsed >= 10`.
  3. On "Done": `finishCapture(name:)`, dismiss, then re-run the same
     `@State` + explicit `refresh()` pattern `LibraryView` uses around
     `RecordingRepository` (`.task { await refresh() }` on appear, called
     again after any mutating action) so the new person shows up immediately.
- "Re-record voice" reopens the same sheet at step 2 (name already known),
  calling `finishCapture(name:replacing: existingID)` so it updates the
  existing row's embedding instead of creating a new person.
- Delete uses `.confirmationDialog` — same title/message shape as Trash's
  existing "Delete Permanently?" dialog, worded for a person instead of a
  recording.
- Any failure (mic permission denied, capture error, model not loaded) shows
  as `ErrorBanner(message:)` inside the sheet — the same component and same
  message-based initializer already used for LM Studio's loopback warning
  and export failures elsewhere in Settings/RecordingDetailView.

## Error handling

- Mic permission denied / capture failure: surfaced via `ErrorBanner`
  exactly as `RecordingView` already does for `coordinator.lastError` — no
  new error-presentation pattern.
- `extractEmbedding` failure (model not loaded, degenerate/silent clip):
  `MaikuError.diarizationFailed`, shown the same way; "Done" stays reachable
  again so the user can just try again without leaving the sheet.
- No confidence/ambiguity UI for recognition matches in this pass — FluidAudio's
  own `speakerThreshold` (0.65 cosine distance, its existing default) decides
  whether a voice in a new recording matches an enrolled person or is treated
  as a new ad-hoc speaker; not configurable in this pass. If false
  matches/misses turn out to be a real problem in practice, exposing that
  threshold is a natural, contained follow-up — not blocking this pass.

## Testing

- `EnrolledSpeakerRepository`: round-trip save/fetch/rename/updateEmbedding/delete
  against an in-memory `DatabaseManager`, matching the existing
  `RecordingRepository`/`SettingsStore` test style.
- `FluidAudioDiarizer.setKnownSpeakers` + seeding: covered at the
  `RecordingCoordinatorTests.FakeDiarizer` level — assert
  `setKnownSpeakers(_:)` was called with the expected roster before
  `startStreaming()`, and that `makeSpeakers` pre-fills `customName` correctly
  when a returned label matches a known speaker's id. `makeSpeakers` is a
  pure static function already (no actor/async needed), so the
  known-name-prefill logic is directly unit-testable without any diarizer at
  all.
- `SpeakerEnrollmentCoordinator`: same testing shape `RecordingCoordinatorTests`
  already uses for `RecordingCoordinator` — a fake `AudioCapturing` producing
  synthetic `speechAudio` chunks, a `FakeDiarizer` returning a canned
  embedding from `extractEmbedding`, asserting `finishCapture` persists the
  right `EnrolledSpeaker` and that `replacing:` updates rather than duplicates.
- As with every other change this session: `swift test` cannot execute in
  this environment (no Xcode, `Testing.framework` unavailable — pre-existing,
  documented in `IMPLEMENTATION_STATUS.md`). Verification is `swift build`
  plus hand-tracing test logic, same as every fix earlier in this session.
- No new tests attempt to verify actual voice-recognition accuracy — that
  needs a real microphone and real distinct voices, which isn't reproducible
  in an automated test; call out in `IMPLEMENTATION_STATUS.md` that this
  needs the user to try it end-to-end after implementation, same as the
  streaming-transcript fixes earlier this session.

## Out of scope (explicitly, not missed)

- Retroactive re-labeling of past recordings.
- Enrolling someone from an existing recording's already-diarized audio
  (the RecordingDetailView shortcut) — explicitly declined for this pass.
- Exposing/tuning FluidAudio's match-confidence threshold in the UI.
- Any onboarding/first-run prompt to enroll — Settings-only entry point.
