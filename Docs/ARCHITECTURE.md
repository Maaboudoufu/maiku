# Architecture

This is the map for someone who has never opened this repository: what the two targets are,
how a recording moves through the system end to end, the state machines that keep that
movement honest, and why each third-party dependency is here at all.

## Two targets

```
MaikuKit  — a library: every model, service, and design-system component. No app lifecycle.
Maiku     — the executable: SwiftUI screens, the app shell, nothing else.
```

Almost everything lives in `MaikuKit` on purpose. A `struct`/`actor` in `MaikuKit` can be
constructed directly in a test with a fake microphone, a stubbed LM Studio server, or an
in-memory database, and never has to import AppKit or stand up a window to be exercised.
`Maiku` is deliberately thin — its job is to wire `MaikuKit` types to SwiftUI views and the
platform (`NSSavePanel`, `AVCaptureDevice`, entitlements), not to hold logic of its own.

## Module map

```
Sources/MaikuKit/
├── Core/             Recording, Speaker, TranscriptSegment, OrganizedRecording, MaikuError,
│                     KeychainTokenStore (Core/Security/)
├── Audio/            AudioCaptureService, AudioFileWriter, AudioPlaybackService, level metering
├── Speech/           SpeechTranscribing protocol + WhisperKitTranscriber, SpeakerDiarizing
│                     protocol + FluidAudioDiarizer, SpeakerAlignmentService, SpeechModelLibrary
├── Intelligence/     LMStudioClient, TranscriptChunker, OrganizationPipeline, OutputValidator,
│                     PromptFactory — the map-reduce organize step (plan §7)
├── Persistence/      DatabaseManager, Migrations, RecordingRepository, SettingsStore, AppPaths
├── Export/           RecordingExporter — Markdown/plain text/JSON/SRT/VTT
├── Processing/       RecordingCoordinator (the state machine driver), RecoveryService,
│                     AppEnvironment (the DI container)
└── DesignSystem/     Theme, PixelButton/Panel/Progress/Waveform, Clawd mascot

Sources/Maiku/
├── MaikuApp.swift    App entry point, RootView, AppDestination routing
└── Features/         One SwiftUI screen per plan §10 destination: Library, Recording,
                       Processing, Recovery, RecordingDetail, Search, Tags, Trash, Settings
```

Every third-party dependency (WhisperKit, FluidAudio) sits behind a local protocol —
`SpeechTranscribing`, `SpeakerDiarizing` — declared in `Speech/`. Production code depends on the
protocol; only one concrete adapter per protocol ever talks to the real library. Tests get a
`FakeTranscriber`/`FakeDiarizer` that implements the same protocol with no model loaded and no
audio hardware. This is also the seam a second speech engine would slot into, if that ever came
up — nothing else in the codebase would need to change.

## State machines

Two state machines exist for two different reasons: one is in memory and drives the UI *during*
a recording; the other is persisted and lets the app answer "where were we?" *after* a
relaunch.

### `RecordingState` — in-memory, drives the UI

Owned by `RecordingCoordinator` (`Processing/ProcessingState.swift`). `canTransition(to:)` is
authoritative — an illegal transition is a thrown/rejected call, not just a discouraged one, so
a coordinator bug fails a test instead of silently producing a half-written recording.

```
idle → requestingPermission → preparingModels → ready → recording ⇄ paused
                                                            │
                                                        stopping
                                                            │
                                              processing(finalizingAudio)
                                                            │
                                              processing(finalTranscription)
                                                            │
                                              processing(finalDiarization)
                                                            │
                                              processing(organizingChunks)
                                                            │
                                              processing(organizingFinal)
                                                            │
                                                         complete
```

Every state can transition to `.failed(stage:message:)`; `.failed` can re-enter the pipeline at
`.idle`, `.ready`, or the right `.processing` stage — nothing already captured is discarded by a
failure (plan §19: audio is never deleted because a later stage failed). `.complete` can also
step back to `processing(.organizingChunks)` — that is "Retry Organization" without
re-transcribing.

### `RecordingStatus` — persisted, survives relaunch

A `Recording` row's `status` column (`Core/Models/Recording.swift`) is coarser and durable:
`recording → finalizingAudio → finalTranscription → finalDiarization → organizingChunks →
organizingFinal → complete`, with `failed` and `trashed` as separate branches. `RecordingCoordinator`
writes this column before every stage transition, which doubles as plan §9's recovery manifest:
`RecordingRepository.fetchInterrupted()` finds every row still in a non-terminal status at
launch — no separate bookkeeping file to drift out of sync with reality.

`trash(id:)` overwrites `status` to `.trashed` without stashing what it was before, so
`restore(id:)` infers it back from `errorMessage` (set only alongside `.failed`, cleared whenever
a stage completes) — `.failed` if that is set, `.complete` otherwise.

## Data flow: one recording, start to finish

```
1. Microphone → AudioCaptureService (actor)
     - writes a lossless .caf to disk continuously (rolling, bounded buffers)
     - streams PCM buffers to both the transcriber and the diarizer at once

2. Live pass (while recording)
     - WhisperKitTranscriber: rolling ~3s window, stable vs. unstable text (plan §6.3)
     - FluidAudioDiarizer: streaming provisional speaker turns
     - SpeakerAlignmentService: badges live transcript segments with a provisional speaker

3. Stop
     - finalizingAudio:      close the audio file, verify it reads back intact
     - finalTranscription:   re-transcribe the whole file at higher accuracy, with word timestamps
     - finalDiarization:     file-based diarization pass; replaces every provisional label
     - (speaker/word alignment reconciles the two into final TranscriptSegment rows)

4. Organize (Intelligence/)
     - TranscriptChunker splits the transcript only if it would exceed the model's context
       budget (silence-aware boundaries, configurable overlap)
     - One chunk: OrganizationPipeline calls LMStudioClient.organizeTranscript directly
     - Multiple chunks: map (summarizeChunk per chunk) → reduce (reduceChunkSummaries) — plan §7.2
     - OutputValidator drops any claim whose sourceSegmentIDs don't resolve to a real segment,
       and any quote whose exactText doesn't match the segment it cites (plan §7.4) —
       hallucination control, not a formatting pass

5. Persist (Persistence/)
     - RecordingRepository writes the Recording, Speaker, and TranscriptSegment rows and the
       OrganizedRecording (as one JSON blob per recording — see the ponytail note in
       Migrations.swift for why that hasn't been normalized into per-item tables)
     - The same write rebuilds that recording's row in the recordingSearch FTS5 index
       (title, transcript, speaker names, notes, tags) so search never goes stale
```

A transcription-only failure (LM Studio unreachable, invalid output after retry) still leaves
the recording `.complete` with its transcript intact — only note generation is retried
independently (plan §5.3, `RecordingCoordinator.retryOrganization(for:)`).

## Persistence

GRDB over a single `DatabaseQueue` (`Persistence/DatabaseManager.swift`), versioned migrations
(`Migrations.swift`), foreign keys on, FTS5 for search. Every id column is stored as `TEXT`
(`.uuidString`), not GRDB's default 16-byte BLOB, so the database stays inspectable with a plain
`sqlite3` shell rather than opaque to anyone debugging it by hand.

`AppSettings` is a second singleton row (`appSettings`, migration `v2`) rather than
`UserDefaults`, so every persisted preference goes through the same backup/restore/inspection
story as everything else — except the LM Studio API token, which lives in the Keychain via
`KeychainTokenStore` and is never written to SQLite (plan §12, non-negotiable).

## Dependency rationale

| Dependency | Why | Pinned |
|---|---|---|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | On-device Whisper via CoreML — transcription never leaves the Mac | `0.18.0` |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | On-device speaker diarization, streaming and file-based | `0.15.5` |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | SQLite wrapper with migrations and first-class FTS5 support | `6.29.3` |
| LM Studio (HTTP, not a package) | The *only* thing maiku talks to over a network — one local process, OpenAI-compatible `/v1/chat/completions` with strict JSON schema output | n/a |

No cloud SDK, analytics library, or crash reporter is a dependency, because none is a feature
(plan §12). Adding one would be a product regression, not an omission.

## Error handling

`MaikuError` (`Core/Errors/MaikuError.swift`) is the one error type that crosses every module
boundary. Each case carries its own `message` and a fixed list of `RecoveryAction`s (plan §19) —
"LM Studio unreachable" always offers Retry/Open Settings/Continue Without Notes, never a bare
error code. Screens render `RecoveryAction` as buttons; they do not invent their own copy per
call site.
