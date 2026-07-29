# Maiku — Local-First macOS Meeting Notes App

> **Instruction to Claude Opus:** Treat this file as both the product specification and the implementation plan. Build the application, not merely a mockup or a written architecture proposal. Work autonomously, make reasonable engineering decisions, keep the repository runnable after every milestone, and document any necessary deviation from this plan.

## 1. Product Summary

Build **Maiku**, a native macOS application that replaces the core personal workflow of Otter.ai while remaining local-first.

Maiku must:

- Record audio from the user's **microphone**.
- Display a **live transcript** while recording.
- Perform **speaker diarization**, showing labels such as `Speaker 1`, `Speaker 2`, and allowing the user to rename them.
- Save the original recording and transcript locally.
- After recording stops, improve the transcript, reconcile speaker labels, and send only transcript text to the user's local **LM Studio API**.
- Automatically produce:
  - A suggested title
  - A concise summary
  - Detailed organized notes
  - Topic sections
  - Key takeaways
  - Decisions
  - Action items
  - Action-item owners and due dates when explicitly stated
  - Open questions and follow-ups
  - Important quotes linked to timestamps
  - Keywords and tags
  - A speaker list
- Let users edit, search, replay, and export their recordings and notes.
- Work without cloud AI services after the required local models have been downloaded.
- Use an **8-bit visual theme** centered on the **Clawd** mascot.

The product name is styled as **maiku** in the interface and `Maiku` in code.

## 2. Fixed Product Decisions

These decisions are already made. Do not ask the user to reconfirm them.

- Platform: **macOS**
- Audio source: **microphone only**
- Live transcription: **required**
- Speaker diarization: **required**
- Speech-to-text: **local Whisper-based engine**
- Note organization: **local model through LM Studio**
- Generated outputs: **all output types listed above**
- Theme: **8-bit/pixel-art**
- Mascot: **the actual Clawd character**, subject to the asset rule in Section 14
- No account system
- No cloud sync in version 1
- No telemetry or remote crash reporting

## 3. Practical Version 1 Assumptions

Use these assumptions so implementation can begin without more questions.

- Target macOS 14 Sonoma or newer.
- Optimize for Apple Silicon Macs first.
- Intel Mac support is not a version 1 release blocker. Keep interfaces portable enough that a `whisper.cpp` fallback could be added later.
- English is the primary version 1 language. Preserve language fields and abstractions so automatic language detection and additional languages can be added later.
- Support at least four speakers in a recording.
- Live transcript and live speaker labels are provisional. The final transcript and final diarization pass performed after recording stops are canonical.
- Recordings may last at least two hours without unbounded memory growth.
- Store data in the user's Application Support directory by default.
- Use the system's current default microphone initially, but include a microphone selector if Core Audio device selection can be implemented reliably without destabilizing the MVP.

## 4. Definition of Done

Version 1 is complete when a user can perform this exact flow:

1. Launch Maiku for the first time.
2. Grant microphone permission.
3. Download or select a local Whisper model.
4. Enter or accept the default LM Studio URL, connect to LM Studio, and select a visible model.
5. Start a recording from the home screen.
6. See a timer, input level, waveform, live transcript, and provisional speaker labels.
7. Pause and resume the recording.
8. Stop the recording.
9. See clear progress while Maiku finalizes audio, improves the transcript, performs final diarization, and generates organized notes through LM Studio.
10. Open the completed recording and see synchronized audio, transcript, named speakers, summary, detailed notes, topics, key takeaways, decisions, action items, questions, quotes, and tags.
11. Click a transcript segment or quote and jump to its audio timestamp.
12. Rename a speaker and see the new name applied throughout the recording.
13. Edit transcript text and generated notes.
14. Search past recordings by title, transcript text, notes, speakers, and tags.
15. Export a recording as Markdown, JSON, TXT, SRT, or VTT.
16. Quit and relaunch without losing data.
17. Complete the workflow with networking disabled, provided local models are already installed and LM Studio is running locally.

## 5. Technical Architecture

### 5.1 Application stack

Build a native app using:

- Swift 6 or the latest stable Swift version supported by the chosen Xcode release
- SwiftUI for the interface
- AVFoundation/AVFAudio for microphone capture and audio playback
- Core Audio APIs only where needed for device enumeration or selection
- Swift Concurrency with actors and structured tasks
- Swift Package Manager for dependencies
- GRDB over SQLite for persistence and full-text search
- `URLSession` and Codable request/response types for the LM Studio client

Do not use Electron, Tauri, a browser wrapper, Python sidecars, cloud APIs, or a local web server for the main app.

### 5.2 Local speech stack

Use protocol-based adapters so speech components can be replaced without rewriting product logic.

Preferred implementation:

- **WhisperKit** for local Whisper transcription on Apple Silicon
- **FluidAudio** for local voice activity detection and speaker diarization
- `AVAudioEngine` for real-time microphone buffers
- `AVAudioConverter` for resampling to the format required by the speech engine

Required protocols:

```swift
protocol SpeechTranscribing: Sendable {
    func prepare(model: SpeechModelConfiguration) async throws
    func startStreaming() async throws
    func accept(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) async throws
    func updates() -> AsyncThrowingStream<TranscriptionUpdate, Error>
    func finishStreaming() async throws -> FinalTranscription
    func transcribeFile(at url: URL) async throws -> FinalTranscription
}

protocol SpeakerDiarizing: Sendable {
    func prepare() async throws
    func startStreaming() async throws
    func accept(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) async throws
    func updates() -> AsyncThrowingStream<DiarizationUpdate, Error>
    func finishStreaming() async throws -> DiarizationResult
    func diarizeFile(at url: URL) async throws -> DiarizationResult
}

protocol VoiceActivityDetecting: Sendable {
    func analyze(_ buffer: AVAudioPCMBuffer) async throws -> VoiceActivityResult
}
```

Do not bind views directly to WhisperKit or FluidAudio types. Wrap third-party APIs behind these protocols.

### 5.3 LM Studio integration

LM Studio is responsible for organizing transcript text, not transcribing audio.

Default configuration:

- Base URL: `http://127.0.0.1:1234`
- Model discovery: `GET /v1/models`
- Structured generation: `POST /v1/chat/completions`
- Use `response_format.type = json_schema` where supported
- Default temperature: `0.2`
- Configurable request timeout
- Optional API token field for users who enable LM Studio authentication

Implement the LM Studio client as an actor:

```swift
actor LMStudioClient {
    func testConnection() async throws -> LMStudioConnectionStatus
    func listModels() async throws -> [LMStudioModel]
    func organizeTranscript(_ request: OrganizationRequest) async throws -> OrganizedRecording
    func summarizeChunk(_ request: ChunkSummaryRequest) async throws -> ChunkSummary
}
```

Use native `URLSession`; do not add a generic OpenAI SDK unless it provides a concrete benefit that outweighs the dependency.

The app must:

- Detect when LM Studio is unreachable.
- Detect when no model is visible.
- Let the user select a model.
- Persist the selected model ID.
- Clearly distinguish “LM Studio is not running,” “no model is available,” “request timed out,” “context is too large,” and “the model returned invalid structured output.”
- Never discard a transcript because note generation failed.
- Allow the user to retry organization without retranscribing audio.
- Warn when the base URL is not loopback because transcript text may leave the machine.

## 6. Recording and Speech Pipeline

### 6.1 Recording state machine

Implement an explicit persisted state machine:

```text
idle
→ requestingPermission
→ preparingModels
→ ready
→ recording
↔ paused
→ stopping
→ finalizingAudio
→ finalTranscription
→ finalDiarization
→ organizingChunks
→ organizingFinal
→ complete
```

Every processing state may transition to a recoverable `failed(stage, error)` state. A failure must preserve all work completed before it.

### 6.2 Audio capture

Requirements:

- Request microphone permission before initializing capture.
- Include a clear `NSMicrophoneUsageDescription`.
- Enable the required macOS Audio Input capability/entitlement.
- Capture with `AVAudioEngine` using an input-node tap.
- Write continuously to a recoverable local audio file rather than retaining the whole recording in memory.
- Prefer a lossless PCM working file such as CAF during capture.
- Feed a resampled mono stream to transcription and diarization.
- Keep capture, file writing, transcription, and UI updates off the main actor.
- Throttle waveform and meter updates so the interface remains responsive.
- Support pause and resume without creating timestamp gaps that break synchronization.
- Handle microphone disconnection with an explicit error and preserve the partial recording.
- Check available disk space before starting and periodically during long recordings.

### 6.3 Live transcription

The live transcript should feel immediate but must avoid constantly rewriting large sections.

Implement:

- Voice activity detection to avoid decoding long silent spans.
- A bounded rolling transcription window with overlap.
- Stable and unstable text ranges.
- Timestamp-aware merging to remove duplicates caused by overlap.
- A visible but unobtrusive indication that live text is provisional.
- Database checkpoints as stable segments are produced.
- UI updates through compact diffable segment changes, not replacement of the entire transcript on every token.

Each segment must include:

```swift
struct TranscriptSegment: Identifiable, Codable, Sendable {
    let id: UUID
    var recordingID: UUID
    var speakerID: UUID?
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var confidence: Double?
    var isFinal: Bool
    var source: SegmentSource
}
```

### 6.4 Speaker diarization

Speaker diarization means “who spoke when.” Do not implement persistent biometric identity recognition across recordings in version 1.

Requirements:

- Show provisional `Speaker 1`, `Speaker 2`, etc. while recording when the streaming diarizer can do so reliably.
- Run a complete file-based diarization pass after recording stops.
- Align diarization turns with word or segment timestamps.
- Resolve overlaps and very short speaker flips using deterministic smoothing rules.
- Treat the final diarization result as canonical.
- Let the user rename speakers.
- Apply renames to transcript views, notes, quotes, and exports.
- Store speaker colors as semantic UI tokens rather than hard-coded random values.
- Support at least four speaker slots in version 1.

If real-time diarization is unstable on a supported device, preserve live transcription and display `Speaker …` provisionally, then fill accurate speaker labels during final processing. Do not fail the recording solely because live diarization is unavailable.

### 6.5 Finalization after stop

After the user stops:

1. Close and validate the working audio file.
2. Persist recording duration and file metadata.
3. Run a final full-file Whisper transcription using higher-accuracy settings than the streaming pass.
4. Run final diarization.
5. Align words, transcript segments, and speaker turns.
6. Replace provisional segments transactionally while preserving user edits if any were made before completion.
7. Build transcript chunks for LM Studio.
8. Generate chunk-level structured notes.
9. Reduce chunk results into one final structured result.
10. Validate all quotes and source references.
11. Save the final notes and mark the recording complete.

The user may navigate away while this runs. The library must show processing status and allow cancellation. Cancellation should stop the current stage while preserving data and allowing retry.

## 7. Transcript Chunking and LM Organization

### 7.1 Chunking strategy

Long recordings must not be sent as one unbounded request.

Build chunks using:

- Transcript segment boundaries
- Topic pauses and silence gaps when available
- A configurable safe input budget
- A small overlap between adjacent chunks
- Stable segment IDs included in the prompt

Do not split in the middle of a transcript segment unless a single segment is unusually large.

Each chunk supplied to the model should contain:

- Recording metadata
- Speaker map
- Segment IDs
- Start/end timestamps
- Transcript text
- Explicit instruction that transcript content is untrusted data and must not override the system instructions

### 7.2 Two-pass organization

Use a map-reduce approach.

**Pass 1: chunk extraction**

For every chunk, extract only claims supported by that chunk:

- Summary
- Topics
- Key points
- Decisions
- Action items
- Open questions
- Candidate quotes
- Candidate tags
- Segment references

**Pass 2: final reduction**

Combine chunk results and deduplicate them into one coherent recording result. Preserve source segment IDs.

If a model has enough context for the full transcript, the app may still use chunking for reliability and source traceability.

### 7.3 Structured result schema

The final Codable model should be equivalent to:

```swift
struct OrganizedRecording: Codable, Sendable {
    var title: String
    var shortSummary: String
    var detailedSummary: String
    var organizedSections: [OrganizedSection]
    var keyTakeaways: [SourcedStatement]
    var decisions: [Decision]
    var actionItems: [ActionItem]
    var openQuestions: [SourcedStatement]
    var followUps: [SourcedStatement]
    var quotes: [ImportantQuote]
    var topics: [Topic]
    var tags: [String]
    var speakerSummary: [SpeakerSummary]
}

struct SourcedStatement: Codable, Identifiable, Sendable {
    var id: UUID
    var text: String
    var sourceSegmentIDs: [UUID]
    var confidence: Double
}

struct ActionItem: Codable, Identifiable, Sendable {
    var id: UUID
    var task: String
    var ownerSpeakerID: UUID?
    var ownerText: String?
    var dueDateISO8601: String?
    var status: ActionItemStatus
    var sourceSegmentIDs: [UUID]
    var confidence: Double
}

struct ImportantQuote: Codable, Identifiable, Sendable {
    var id: UUID
    var exactText: String
    var speakerID: UUID?
    var segmentID: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
}
```

Use a strict JSON schema in the LM Studio request. Decode into Codable types and validate again in application code.

### 7.4 Hallucination controls

The organizer must not invent details.

- Unknown owners and dates must be `null`, not guessed.
- Every decision, action item, question, quote, and important claim must reference one or more transcript segment IDs.
- Quotes must match the referenced transcript text after whitespace normalization.
- Invalid quotes are discarded or flagged, never silently accepted.
- Relative dates should remain as spoken unless the transcript provides enough date context to resolve them safely.
- Include confidence values and display low-confidence items subtly.
- If structured output decoding fails, retry once with a repair request containing the validation errors. If it still fails, preserve the raw response in local diagnostics and show a retryable error.

## 8. Persistence and Data Model

Use GRDB and SQLite migrations. Store audio files on disk and references in the database; do not store audio blobs in SQLite.

Core tables/models:

- `recordings`
- `transcript_segments`
- `speakers`
- `recording_speakers`
- `organized_results`
- `organized_sections`
- `action_items`
- `decisions`
- `quotes`
- `topics`
- `tags`
- `recording_tags`
- `processing_jobs`
- `app_settings`

Suggested recording fields:

```text
id
created_at
updated_at
title
status
recording_started_at
recording_ended_at
duration_seconds
audio_relative_path
working_audio_relative_path
transcription_model
lm_studio_model
language
error_stage
error_message
processing_progress
```

Requirements:

- Use migrations from the first commit.
- Enable SQLite foreign keys.
- Use FTS5 for title, transcript, speaker names, notes, and tags.
- Wrap replacement of provisional transcript segments in a transaction.
- Persist processing progress so interrupted work can be recovered.
- Never store absolute paths when a path relative to the app data directory is sufficient.
- Provide one-click deletion of a recording and all derived data.
- Move deleted recordings to an internal Trash state first, then support permanent deletion.

Default data layout:

```text
~/Library/Application Support/Maiku/
├── Maiku.sqlite
├── Audio/
│   └── <recording-uuid>/
│       ├── capture.caf
│       └── archive.m4a        # optional derived archive
├── Models/                    # only if library APIs support a custom location
├── Exports/
├── Recovery/
└── Logs/
```

## 9. Crash Recovery and Reliability

A recording app must prioritize captured audio over visual polish.

Implement:

- Continuous audio writes.
- Periodic database checkpoints.
- A lightweight recovery manifest for an active recording.
- Detection of interrupted recordings on launch.
- A recovery screen offering:
  - Recover and process
  - Keep raw audio only
  - Delete
- Atomic writes for small metadata files.
- Cancellation-aware tasks.
- Bounded audio and transcript buffers.
- File integrity checks before final processing.
- Retryable processing stages.
- A local diagnostic log with automatic size rotation.

Do not upload logs. Add an “Export Diagnostics” action that creates a local redacted text or ZIP file. Redact transcript content by default unless the user explicitly includes it.

## 10. User Experience and Screens

### 10.1 Navigation

Use a macOS-appropriate `NavigationSplitView`.

Primary destinations:

- Library
- Search
- Tags
- Trash
- Settings

The default launch destination is the Library.

### 10.2 Onboarding

Create a short first-run flow with no account creation:

1. Welcome to Maiku
2. Privacy promise: local-first, no telemetry
3. Microphone permission
4. Speech model setup with download progress and storage size
5. LM Studio connection test
6. LM Studio model selection
7. Ready screen with a test recording option

Do not require LM Studio to begin recording. If it is unavailable, users may record and transcribe, then organize later.

### 10.3 Library screen

Show:

- Large primary “Record” button
- Clawd idle state
- Recent recordings
- Processing indicators
- Search field
- Filters for date, status, speakers, and tags
- Empty state that explains the workflow in one sentence

Recording cards should show title, date, duration, speakers, tags, status, and the first line of the summary.

### 10.4 Recording screen

Show:

- Large Clawd listening animation holding a microphone
- Recording timer
- Current microphone name
- Input level meter and pixel waveform
- Live transcript
- Provisional speaker badges
- Pause/resume button
- Stop button
- A clear red recording indicator

The screen must remain legible and calm. The 8-bit style must not make body text hard to read.

### 10.5 Processing screen

Show named stages rather than an indeterminate spinner:

- Saving audio
- Finalizing transcript
- Identifying speakers
- Organizing notes
- Saving results

Clawd should sort pixel note cards during this state. Show completed stages and current progress when available. Let the user leave the screen without canceling the work.

### 10.6 Recording detail screen

Use a flexible layout with:

- Header: editable title, date, duration, status, tags
- Persistent compact audio player with scrubber and playback speed
- Tabs or segmented navigation:
  - Overview
  - Notes
  - Transcript
  - Action Items
- Speaker editor
- Export menu
- Retry organization action

Overview should prioritize the summary, key takeaways, decisions, and action items.

Transcript requirements:

- Timestamped speaker turns
- Click to seek audio
- Inline editing
- Current playback segment highlighting
- Search within recording
- Optional confidence indicator

Notes requirements:

- Editable sections
- Source buttons that jump to supporting transcript segments
- Copy section action
- Regenerate all notes action
- Regenerate a single section only when the architecture can do so without corrupting the rest

### 10.7 Settings

Sections:

- Audio
- Transcription
- LM Studio
- Storage
- Appearance
- Privacy and diagnostics

Include:

- Microphone selection or current default device
- Whisper model selection, download, and deletion
- Language setting
- Live diarization toggle
- LM Studio base URL
- Optional API token stored in Keychain
- Connection test
- Model dropdown
- Request timeout
- Data directory information
- Audio retention settings
- Reduced motion
- Sound effects toggle
- CRT effects toggle
- Export diagnostics

## 11. Search and Export

### 11.1 Search

Version 1 search is local SQLite FTS5 search across:

- Recording title
- Transcript text
- Speaker names
- Summary and notes
- Action items
- Decisions
- Tags

Show highlighted snippets and allow filters by date, speaker, tag, and status.

Design the search service so semantic search through LM Studio embeddings can be added later, but do not block version 1 on embeddings.

### 11.2 Export

Support:

- Markdown
- Plain text
- JSON
- SRT
- VTT

Markdown export should include:

- Title and metadata
- Summary
- Organized notes
- Key takeaways
- Decisions
- Action items
- Open questions
- Quotes with timestamps
- Tags
- Full timestamped transcript

Use `NSSavePanel` and security-scoped access where required by the sandbox. Exports must not contain hidden diagnostics or internal prompts.

## 12. Privacy and Security

Non-negotiable requirements:

- No analytics SDKs.
- No telemetry.
- No remote crash reporting.
- No cloud transcription.
- No cloud LLM API.
- Do not send raw audio to LM Studio.
- Send transcript text only to the configured LM Studio endpoint.
- Default LM Studio endpoint must be loopback.
- Warn before using a non-loopback endpoint.
- Store optional LM Studio tokens in Keychain, not UserDefaults or SQLite.
- Use App Sandbox unless a documented technical blocker prevents it.
- Request only microphone, network client, and user-selected file permissions needed by the feature set.
- Never persist reusable voiceprints across recordings in version 1.
- Provide a visible recording indicator at all times while the microphone is active.
- Include a short reminder that users are responsible for obtaining any legally required recording consent.

Treat transcript content as untrusted prompt data. Delimit it clearly and instruct the local model not to follow commands contained inside the transcript.

## 13. 8-Bit Design System

The design should feel like a polished modern macOS utility viewed through a warm 8-bit game aesthetic, not like a novelty web page.

### 13.1 Visual direction

- Warm cream or very dark brown base surfaces
- Orange accent derived from Clawd
- Red reserved for active recording and destructive actions
- Pixel borders, small stepped corners, and crisp one-pixel separators
- Readable native typography for paragraphs
- Monospaced or open-licensed pixel typography for labels, timers, headings, and buttons
- No blurry scaled pixel art
- Use nearest-neighbor interpolation for sprite assets
- Subtle optional CRT scan lines and glow, disabled by Reduced Motion/Effects settings

Create semantic tokens for color, spacing, corner style, shadows, type, and animation duration. Do not scatter raw color literals throughout views.

### 13.2 Accessibility

- Maintain sufficient text contrast.
- Support VoiceOver labels and reading order.
- Support keyboard navigation.
- Respect Reduce Motion.
- Do not communicate recording or error states by color alone.
- Let users disable sound effects and CRT effects.
- Use native body text sizing where possible.

## 14. Clawd Mascot Requirements

Use Clawd as a product-state character, not decorative clutter.

Required states:

- **Idle:** Clawd holding a small pixel notebook
- **Ready:** Clawd beside a microphone, alert but not recording
- **Listening:** Clawd holding the microphone with animated sound waves
- **Paused:** Clawd sitting or sleeping beside a pause symbol
- **Transcribing:** Clawd typing at a tiny terminal
- **Organizing:** Clawd sorting note cards into labeled folders
- **Complete:** Clawd holding a finished page with a checkmark
- **Error:** Clawd holding a tangled or unplugged microphone cable
- **LM Studio disconnected:** Clawd beside an unplugged local computer

Implement a reusable mascot state component:

```swift
enum ClawdState: Equatable, Sendable {
    case idle
    case ready
    case listening(level: Float)
    case paused
    case transcribing
    case organizing(progress: Double?)
    case complete
    case error
    case lmStudioDisconnected
}
```

### Asset rule

The actual Clawd character is associated with Anthropic. Use only Clawd artwork that the user supplies or has permission to use. Do not scrape, trace, or download protected artwork from the web.

Build the complete mascot animation system and define an asset manifest. If authorized Clawd sprites are not present in the repository, use a clearly labeled temporary placeholder component while preserving the exact states and expected filenames. Do not silently substitute a different permanent mascot.

Suggested asset manifest:

```text
Resources/Clawd/
├── clawd_idle_notebook.png
├── clawd_ready_mic.png
├── clawd_listening_01.png
├── clawd_listening_02.png
├── clawd_listening_03.png
├── clawd_listening_04.png
├── clawd_paused.png
├── clawd_transcribing_01.png
├── clawd_transcribing_02.png
├── clawd_organizing_01.png
├── clawd_organizing_02.png
├── clawd_organizing_03.png
├── clawd_complete.png
├── clawd_error.png
└── clawd_lmstudio_disconnected.png
```

If the app is prepared for public distribution, include an About-screen statement that Maiku is an independent project and is not affiliated with Anthropic, unless the user has obtained an agreement that permits different language.

## 15. Suggested Repository Structure

Adapt this to the existing repository rather than reorganizing blindly.

```text
Maiku/
├── App/
│   ├── MaikuApp.swift
│   ├── AppEnvironment.swift
│   ├── AppRouter.swift
│   └── AppState.swift
├── Core/
│   ├── Models/
│   ├── Errors/
│   ├── Utilities/
│   ├── Logging/
│   └── Extensions/
├── Audio/
│   ├── AudioCaptureService.swift
│   ├── AudioFileWriter.swift
│   ├── AudioDeviceService.swift
│   ├── AudioLevelMeter.swift
│   └── AudioPlaybackService.swift
├── Speech/
│   ├── SpeechTranscribing.swift
│   ├── WhisperKitTranscriber.swift
│   ├── VoiceActivityDetecting.swift
│   ├── FluidAudioVAD.swift
│   ├── SpeakerDiarizing.swift
│   ├── FluidAudioDiarizer.swift
│   ├── TranscriptMerger.swift
│   └── SpeakerAlignmentService.swift
├── Intelligence/
│   ├── LMStudioClient.swift
│   ├── LMStudioModels.swift
│   ├── TranscriptChunker.swift
│   ├── OrganizationPipeline.swift
│   ├── OrganizationSchema.swift
│   ├── PromptFactory.swift
│   └── OutputValidator.swift
├── Persistence/
│   ├── DatabaseManager.swift
│   ├── Migrations/
│   ├── Repositories/
│   └── FTS/
├── Processing/
│   ├── RecordingCoordinator.swift
│   ├── ProcessingCoordinator.swift
│   ├── ProcessingState.swift
│   └── RecoveryService.swift
├── Features/
│   ├── Onboarding/
│   ├── Library/
│   ├── Recording/
│   ├── Processing/
│   ├── RecordingDetail/
│   ├── Search/
│   ├── Tags/
│   ├── Trash/
│   └── Settings/
├── DesignSystem/
│   ├── Theme.swift
│   ├── PixelComponents/
│   ├── Typography/
│   ├── Mascot/
│   └── Accessibility/
├── Resources/
│   ├── Assets.xcassets
│   ├── Clawd/
│   └── SampleData/
└── Maiku.entitlements

MaikuTests/
├── Audio/
├── Speech/
├── Intelligence/
├── Persistence/
├── Processing/
└── Fixtures/

MaikuUITests/
Docs/
├── ARCHITECTURE.md
├── PRIVACY.md
├── MODEL_SETUP.md
└── TROUBLESHOOTING.md
scripts/
├── build.sh
├── test.sh
└── lint.sh
README.md
IMPLEMENTATION_STATUS.md
THIRD_PARTY_NOTICES.md
```

## 16. Milestones

Each milestone must leave a buildable app. Update `IMPLEMENTATION_STATUS.md` as work progresses.

### Milestone 0 — Repository assessment and risk spike

- Inspect every existing file before replacing architecture.
- Record current build instructions and dependencies.
- Confirm the app can capture microphone audio.
- Confirm WhisperKit can transcribe a short local sample.
- Confirm FluidAudio can produce diarization output on a short sample.
- Confirm LM Studio connection and strict JSON output using a mock or live local server.
- Document dependency versions and licenses.
- Identify minimum macOS/Xcode requirements from the actual selected package versions.

**Exit criteria:** Small technical spikes prove all four critical paths: microphone, transcription, diarization, and LM Studio structured output.

### Milestone 1 — Thin end-to-end vertical slice

- Basic SwiftUI app shell
- Microphone permission
- Start/stop recording
- Save audio locally
- Live transcript
- Final transcript
- Simple final diarization
- LM Studio connection
- Generate and display title plus summary
- Persist one recording
- Basic Clawd idle/listening/organizing states, placeholders allowed under the asset rule

**Exit criteria:** A user can record a short conversation and receive a saved, titled summary locally.

### Milestone 2 — Reliable recording and recovery

- Explicit state machine
- Pause/resume
- Rolling file writes
- Input meter and waveform
- Stable/unstable transcript merging
- Database checkpoints
- Disk-space checks
- Interrupted recording recovery
- Robust microphone and model errors

**Exit criteria:** A long recording can survive navigation, app suspension where applicable, and a simulated interruption without losing captured audio.

### Milestone 3 — Final diarization and synchronized transcript

- Streaming provisional speaker labels
- Final file-based diarization
- Speaker/word alignment
- Speaker smoothing
- Rename speakers
- Audio player and click-to-seek transcript
- Editable transcript

**Exit criteria:** Multi-speaker sample recordings produce usable speaker turns and synchronized playback.

### Milestone 4 — Complete organization pipeline

- Transcript chunker
- Chunk extraction schema
- Final reduction schema
- Strict JSON schema requests
- Source segment references
- Quote validation
- Invalid-output repair retry
- All required note categories
- Retry organization independently of transcription

**Exit criteria:** A long transcript produces complete, sourced, editable organized notes without exceeding the configured context budget.

### Milestone 5 — Library, search, export, and settings

- Recording library
- Processing status cards
- FTS5 search
- Tags
- Trash and permanent deletion
- Markdown, TXT, JSON, SRT, VTT export
- Speech model management
- LM Studio settings and model picker
- Storage and diagnostics settings

**Exit criteria:** Users can manage a useful local archive of recordings.

### Milestone 6 — Pixel polish, accessibility, and release readiness

- Full 8-bit design system
- Authorized Clawd assets wired to every state
- Reduced motion and effects controls
- VoiceOver and keyboard pass
- App icon and About screen
- Privacy documentation
- Third-party notices
- Automated tests
- Manual acceptance checklist
- Signed/notarized development distribution documentation if credentials are available

**Exit criteria:** All Definition of Done items pass on a clean supported Mac user account.

## 17. Testing Requirements

### 17.1 Unit tests

Cover at minimum:

- Recording state transitions
- Pause/resume timestamp accounting
- Transcript overlap merging and deduplication
- Speaker-turn alignment and smoothing
- Transcript chunk boundaries and overlap
- JSON schema decoding and validation
- Hallucinated/invalid quote rejection
- Unknown owner/date handling
- Database migrations
- FTS indexing
- File-path safety
- Recovery manifest handling
- LM Studio error mapping

### 17.2 Integration tests

- Mock LM Studio HTTP server returning valid, invalid, slow, and truncated responses
- Persistence round trip for a completed recording
- Processing resume from every persisted stage
- Export format snapshots
- Audio fixture through transcription adapter when feasible in CI
- Diarization fixture through diarization adapter when feasible in CI

Do not make normal CI depend on an installed LM Studio instance or downloaded multi-gigabyte models. Use protocol mocks and small opt-in local integration tests.

### 17.3 UI tests

Test:

- First-run onboarding
- Permission-denied path
- Start/pause/resume/stop flow with mocked services
- Processing progress
- Recording detail navigation
- Speaker rename
- Search
- Export initiation
- LM Studio disconnected state

### 17.4 Manual acceptance scenarios

- One speaker in a quiet room
- Two speakers in a quiet room
- Four speakers with interruptions
- Background fan noise
- Long silence
- One-hour recording
- Microphone disconnected during recording
- Disk space becomes low
- App terminated during recording
- App terminated during final processing
- LM Studio stopped during organization
- LM Studio model returns malformed JSON
- Offline launch with models already installed

## 18. Performance Requirements

- Never retain an entire long recording as raw PCM in memory.
- Keep UI work on the main actor and ML/audio work off it.
- Bound all rolling buffers.
- Batch database writes where appropriate.
- Throttle waveform rendering.
- Make all long-running tasks cancellable.
- Show progress or named stages for operations longer than a brief interaction.
- Target a live transcript delay of roughly two to five seconds on a baseline Apple Silicon Mac with the balanced speech model, while preferring correctness over a misleadingly low latency.
- Degrade gracefully by disabling live diarization before dropping audio or live transcription.

## 19. Error Messages and Recovery Actions

Every major error should explain what happened and provide a useful action.

Examples:

- **Microphone permission denied:** Open System Settings, Retry
- **No microphone found:** Refresh Devices
- **Speech model missing:** Download Model, Choose Model
- **Speech model failed to load:** Retry, Select Smaller Model
- **LM Studio unreachable:** Retry, Open Settings, Continue Without Notes
- **No LM Studio model visible:** Refresh Models, Continue Without Notes
- **Context too large:** Retry With Smaller Chunks
- **Invalid model output:** Retry Organization, View Diagnostics
- **Low disk space:** Choose Storage Location, Delete Old Recordings, Stop Safely
- **Interrupted recording found:** Recover and Process, Keep Audio, Delete

Never present only an opaque error code.

## 20. Documentation Deliverables

Maintain:

- `README.md`: what Maiku does, screenshots/placeholders, quick start, build steps
- `Docs/ARCHITECTURE.md`: modules, state machines, data flow, dependency rationale
- `Docs/PRIVACY.md`: exactly what stays local and what reaches LM Studio
- `Docs/MODEL_SETUP.md`: Whisper and diarization model setup, disk requirements, offline behavior
- `Docs/TROUBLESHOOTING.md`: microphone, model, LM Studio, and recovery issues
- `THIRD_PARTY_NOTICES.md`: dependencies, model licenses, fonts, and artwork attribution
- `IMPLEMENTATION_STATUS.md`: milestone checklist, completed work, known limitations, next task

## 21. Working Rules for Claude Opus

1. Inspect the repository before editing.
2. Begin by writing or updating `IMPLEMENTATION_STATUS.md` with the milestone checklist.
3. Prefer a working vertical slice over broad unfinished scaffolding.
4. Do not stop at mockups, pseudocode, or TODO-only files.
5. Do not place fake implementations behind production buttons.
6. Use mocks only in previews and tests.
7. Pin dependency versions after verifying current compatibility.
8. Read the current official APIs for WhisperKit, FluidAudio, AVAudioEngine, and LM Studio before coding adapters.
9. Keep third-party types behind local protocols.
10. Run formatting, build, and tests after each meaningful change.
11. Fix warnings that indicate correctness, concurrency, or lifecycle problems.
12. Never delete captured audio because a later processing stage fails.
13. Never add a cloud fallback.
14. Never add analytics or telemetry.
15. Do not ask for routine implementation preferences. Make a sensible decision and document it.
16. Ask the user only when blocked by credentials, an absent authorized Clawd asset, or a product decision that cannot be reversed cheaply.
17. When authorized Clawd artwork is absent, complete all code using the documented placeholder asset contract rather than blocking the entire app.
18. Keep a short “Known limitations” section current.
19. At the end of each milestone, report the files changed, commands run, tests passed, and remaining risks.
20. Do not claim a feature works until it has been built and tested.

## 22. Build Validation

Provide scripts that perform equivalent checks to:

```bash
xcodebuild \
  -scheme Maiku \
  -destination 'platform=macOS' \
  build

xcodebuild \
  -scheme Maiku \
  -destination 'platform=macOS' \
  test
```

Use the actual project/workspace arguments required by the repository. Scripts must exit nonzero on failure.

## 23. Out of Scope for Version 1

Do not allow these to delay the MVP:

- System-audio capture
- iPhone/iPad versions
- Windows or Linux versions
- Cloud sync
- Team workspaces
- User accounts
- Calendar integrations
- Meeting-bot participation in Zoom/Teams/Meet
- Persistent cross-recording voice recognition
- Remote collaboration
- Semantic search
- Automatic model downloads without user action
- Public plugin marketplace

Design clean extension points, but do not implement speculative infrastructure for these features.

## 24. Implementation References

Verify current APIs before implementation:

- LM Studio developer docs: `https://lmstudio.ai/docs/developer`
- LM Studio local server: `https://lmstudio.ai/docs/developer/core/server`
- LM Studio OpenAI-compatible API: `https://lmstudio.ai/docs/developer/openai-compat`
- LM Studio structured output: `https://lmstudio.ai/docs/developer/openai-compat/structured-output`
- WhisperKit: `https://github.com/argmaxinc/WhisperKit`
- FluidAudio: `https://github.com/FluidInference/FluidAudio`
- FluidAudio diarization guide: `https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md`
- Apple AVAudioEngine: `https://developer.apple.com/documentation/avfaudio/avaudioengine`
- Apple microphone authorization: `https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos`

## 25. First Action

Start now with Milestone 0.

- Inspect the repository.
- Create `IMPLEMENTATION_STATUS.md`.
- Identify the existing build system.
- Verify the four critical technical paths with the smallest possible spikes.
- Then implement Milestone 1 as a real end-to-end slice.

Do not respond with another plan. Begin making the application.
