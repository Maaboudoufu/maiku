# Model Setup

maiku uses three kinds of model. Two run on-device and are downloaded once; the third runs
inside LM Studio, which you manage yourself.

| Purpose | Engine | Where it runs |
|---|---|---|
| Speech to text | WhisperKit (Core ML) | On-device |
| Who spoke when | FluidAudio (Core ML) | On-device |
| Organizing notes | Your choice | LM Studio, on your machine |

## Speech-to-text models

Pick a Whisper size in Settings → Transcription. Bigger is more accurate and slower. On Apple
Silicon the encoder runs on the Neural Engine, so the jump from `tiny` to `base` costs far less
than the parameter count suggests.

| Model | Download | Good for |
|---|---|---|
| `tiny.en` | ~75 MB | Testing, very fast machines, quick notes |
| `base.en` | ~145 MB | A sensible default |
| `small.en` | ~480 MB | Noticeably better on accents and cross-talk |
| `large-v3_turbo` | ~1.6 GB | Best accuracy; use when the recording matters |

English-only variants (`.en`) are more accurate than the multilingual models of the same size,
and version 1 targets English. maiku keeps a language field throughout, so multilingual support
is a settings change later rather than a rewrite.

Models come from the Hugging Face repository `argmaxinc/whisperkit-coreml` and are cached by
WhisperKit. The first run of a newly downloaded model is slower while Core ML compiles it for
your specific chip; that cost is paid once.

**Recommendation:** `base.en` for live transcription, and the same or larger for the final pass.
The live pass optimizes for latency, the final pass for accuracy — they do not have to match.

## Speaker diarization models

Two small Core ML models, downloaded together on first use, roughly 25 MB total:

- `pyannote_segmentation` — finds speech regions and speaker changes
- `wespeaker_v2` — produces the embeddings used to decide which regions share a speaker

There is nothing to configure. They live under
`~/Library/Application Support/FluidAudio/Models/speaker-diarization`.

**Expect imperfection.** On our test fixture, diarization found the correct number of speakers
and placed the first boundary within 50 ms, but drifted more than a second on a later one.
maiku applies smoothing and alignment on top of the raw output, and you can always correct
speaker assignments by hand. Quality improves substantially with clean audio, a decent
microphone, and speakers who do not talk over each other.

## LM Studio

maiku uses LM Studio only to turn transcript text into organized notes. It never sends audio.

1. Install [LM Studio](https://lmstudio.ai) and download a model.
2. Start the local server (LM Studio's Developer tab, or `lms server start`). The default
   endpoint is `http://127.0.0.1:1234`.
3. In maiku → Settings → LM Studio, press **Test Connection**, then pick a model.

**Choosing a model.** Note generation is a structured-output task: the model must follow a
strict JSON schema and resist inventing details. Instruction-tuned models in the 8–30B range do
this well. A 9B model produced correct, well-sourced notes in about 15 seconds for a short
transcript in our testing. Very small models (under ~4B) tend to violate the schema or
hallucinate owners and dates.

**Context length matters more than parameter count** for long meetings. maiku chunks transcripts
so they fit, but fewer chunks means better cross-referencing. An hour of conversation is very
roughly 10–15k tokens.

If LM Studio is unreachable or has no model loaded, maiku says so specifically and lets you keep
recording. Notes can be generated later without retranscribing.

## Disk use

| | |
|---|---|
| Speech models | 100 MB – 1.7 GB depending on your choice |
| Diarization models | ~25 MB |
| Audio | roughly 10 MB per minute for the lossless working file |
| Database | small — text only |

maiku checks free space before recording and periodically during long sessions.

## Working offline

Once the speech models are downloaded and LM Studio is running locally, maiku needs no network
connection at all. You can verify this by turning off Wi-Fi and completing a full
record → transcribe → organize cycle. Models are never re-downloaded automatically, and maiku
never downloads anything without you asking.
