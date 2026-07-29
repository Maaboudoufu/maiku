# Privacy

maiku is local-first. This document states precisely what stays on your Mac and what leaves it,
so you can verify the claim rather than take it on faith.

## What never leaves your Mac

- **Your audio.** Recordings are written to disk and read back for transcription and playback.
  They are never uploaded anywhere, and are never sent to LM Studio — LM Studio organizes text,
  it does not transcribe audio.
- **Speech processing.** Transcription (WhisperKit) and speaker diarization (FluidAudio) run
  entirely on-device using Core ML.
- **Your database.** Transcripts, notes, speaker names, tags and search indexes live in a local
  SQLite file.
- **Any API token you configure.** Stored in the macOS Keychain, never in UserDefaults, never in
  the database, never in exports or diagnostics.

## What leaves the app, and where it goes

Exactly one thing: **transcript text**, sent to the LM Studio endpoint you configure, to
generate notes.

The default endpoint is `http://127.0.0.1:1234` — loopback, meaning the request never touches a
network interface and cannot leave the machine. If you change it to a non-loopback address, the
transcript will travel to that host, and maiku warns you before it does. It does not stop you;
it makes sure the choice is deliberate.

Note generation is optional. You can record, transcribe and diarize with LM Studio never
running, and organize later — or never.

## Network access

maiku makes network requests in exactly three situations, all of which you initiate:

1. **Downloading speech models**, from Hugging Face, when you ask it to (first run or from
   Settings). Once downloaded, they are cached and never fetched again.
2. **Talking to LM Studio**, at your configured endpoint.
3. Nothing else.

There is no analytics SDK, no telemetry, no remote crash reporting, no update check, no license
check, and no account system. With models already installed and LM Studio running locally,
maiku works with networking fully disabled — this is a tested requirement, not an aspiration.

## Diagnostics

maiku keeps a local rotating log to help you debug problems. It is never uploaded. "Export
Diagnostics" writes a local file, and **redacts transcript content by default** — you must opt
in explicitly to include it. Exports of your recordings contain your content only, never
internal prompts or diagnostic data.

## Voice biometrics

Speaker diarization answers "who spoke when" *within a single recording*. maiku does **not**
build or store reusable voiceprints, and cannot recognise the same person across two different
recordings. Speaker embeddings exist only in memory while a recording is being processed and are
discarded afterwards.

## Sandboxing and permissions

maiku runs under the macOS App Sandbox and requests only:

| Entitlement | Why |
|---|---|
| `device.audio-input` | Recording the microphone — the core feature |
| `network.client` | Reaching LM Studio, and downloading speech models when asked |
| `files.user-selected.read-write` | Writing exports where you choose to put them |

It does not request access to your Documents, Desktop, Downloads, contacts, calendar, camera, or
location.

## Your data on disk

```
~/Library/Application Support/Maiku/
├── Maiku.sqlite     transcripts, notes, speakers, tags, search index
├── Audio/           one folder per recording
├── Exports/         exports you generate
├── Recovery/        manifests for interrupted recordings
└── Logs/            local rotating diagnostic log
```

Deleting a recording moves it to an in-app Trash first; permanently deleting it removes the
database rows and the audio files together. Deleting the folder above removes everything maiku
has ever stored, and maiku will start fresh next launch.

## Recording other people

maiku is a recording device. Laws on recording conversations vary — some jurisdictions require
every participant to consent, others only one. Complying is your responsibility. maiku shows a
visible indicator whenever the microphone is live so that nobody in the room is misled about
what is happening.
