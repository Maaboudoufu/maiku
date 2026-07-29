# maiku

Local-first meeting notes for macOS. Record a conversation, get a transcript with speaker
labels, and let a language model running on your own machine turn it into organized notes.

Nothing is sent to a cloud service. Audio never leaves your Mac at all; only transcript **text**
is sent, and only to the LM Studio endpoint you configure — loopback by default.

> **Status:** in development. See [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md) for
> what actually works today, and the milestone checklist for what does not yet.

## What it does

- Records your microphone and shows a live transcript as you speak
- Labels who spoke when, and lets you rename `Speaker 1` to a real name everywhere at once
- After you stop, re-transcribes at higher accuracy and runs a final speaker pass
- Sends the transcript to your local LM Studio model to produce a title, summary, organized
  notes, topics, takeaways, decisions, action items, open questions, quotes, and tags
- Every generated claim cites the transcript segments it came from — click to hear it
- Search everything locally, and export to Markdown, TXT, JSON, SRT, or VTT

## Requirements

- macOS 14 Sonoma or newer, Apple Silicon
- Swift 6.0+ toolchain (Xcode, or just the Command Line Tools — see below)
- [LM Studio](https://lmstudio.ai) with at least one model downloaded, for note generation.
  Recording and transcription work without it.
- Roughly 1–3 GB of disk for speech models, depending on which Whisper size you pick

## Quick start

```bash
git clone <this repo> && cd maiku
./scripts/build.sh          # builds and signs dist/Maiku.app
open dist/Maiku.app
```

On first launch maiku asks for microphone permission, offers to download a Whisper model, and
tests the connection to LM Studio.

## Building

There is no `.xcodeproj`. maiku is a Swift package, and `scripts/build.sh` wraps the built
executable in a proper `Maiku.app` bundle — macOS will not grant microphone permission
otherwise. This also means the project builds with only the Command Line Tools installed; a
full Xcode is optional.

```bash
./scripts/build.sh          # debug build + app bundle
./scripts/build.sh release  # optimized build
./scripts/test.sh           # unit tests
./scripts/lint.sh           # swift-format lint; `./scripts/lint.sh fix` to apply
```

All three exit nonzero on failure. If you have Xcode installed, `open Package.swift` works too.

## Documentation

| | |
|---|---|
| [`Docs/ARCHITECTURE.md`](Docs/ARCHITECTURE.md) | Modules, state machines, data flow |
| [`Docs/PRIVACY.md`](Docs/PRIVACY.md) | Exactly what stays local and what reaches LM Studio |
| [`Docs/MODEL_SETUP.md`](Docs/MODEL_SETUP.md) | Speech models, disk use, offline behaviour |
| [`Docs/TROUBLESHOOTING.md`](Docs/TROUBLESHOOTING.md) | Microphone, model, LM Studio, recovery |
| [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) | Dependencies, model and artwork licenses |

## A note on recording others

maiku will happily record any conversation you point it at. Whether you are allowed to is your
responsibility — consent requirements for recording differ by jurisdiction, and in many places
you must tell the other participants. maiku shows a recording indicator whenever the microphone
is live, but that is not a substitute for asking.

## Mascot

The app is themed around Clawd, who belongs to Anthropic. No Clawd artwork ships in this
repository; the mascot renders as a labelled placeholder until you supply artwork you are
authorized to use. See [`Resources/Clawd/README.md`](Resources/Clawd/README.md).

maiku is an independent project and is not affiliated with Anthropic.
