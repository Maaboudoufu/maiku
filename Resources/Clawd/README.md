# Clawd sprites — deliberately not included

The Clawd character belongs to Anthropic. This directory ships **no Clawd
artwork**, and none may be scraped, traced, downloaded, or model-generated into a
lookalike (plan §14 asset rule).

Until authorized art is dropped in here, `ClawdView` draws an obviously generic
pixel creature carrying a per-state prop, with a "PLACEHOLDER ART" badge under
it. That placeholder is a stand-in so the state machine, frame timing, and
VoiceOver wiring are real and testable — it is **not** the product's mascot and
must not ship as one.

## Expected files

`ClawdAssetManifest` looks up these exact names. Nothing else in the app knows a
filename, so getting the names right is the whole integration.

| File | State | Frame hold |
| --- | --- | --- |
| `clawd_idle_notebook.png` | idle — holding a small notebook | still |
| `clawd_ready_mic.png` | ready — beside a mic, alert, not recording | still |
| `clawd_listening_01.png` … `_04.png` | listening — holding the mic, sound waves | 0.12 s |
| `clawd_paused.png` | paused — sitting/sleeping beside a pause symbol | still |
| `clawd_transcribing_01.png`, `_02.png` | transcribing — typing at a tiny terminal | 0.25 s |
| `clawd_organizing_01.png` … `_03.png` | organizing — sorting cards into folders | 0.22 s |
| `clawd_complete.png` | complete — finished page with a checkmark | still |
| `clawd_error.png` | error — tangled or unplugged mic cable | still |
| `clawd_lmstudio_disconnected.png` | LM Studio disconnected — unplugged computer | still |

Fifteen files total. A partial set is fine: any frame that fails to resolve falls
back to the placeholder for that frame only, so art can land one state at a time.

## Format

- **64 × 64 px** PNG (`ClawdAssetManifest.spriteSize`), transparent background,
  sRGB, no embedded scale suffix (`@2x` is not used — the sprite is scaled at
  draw time, not chosen by density).
- Author at 1 art pixel = 1 image pixel. Do not pre-scale a 16 × 16 drawing up
  to 64 × 64 with a smooth filter; that bakes in the blur the design forbids.
- Every frame of a sequence must be the same size, with the character on the same
  baseline, or the loop will jitter.
- Drawn with `.interpolation(.none).antialiased(false)` — nearest-neighbour, no
  smoothing (plan §13.1). Integer multiples of 64 (64, 128, 192) give every
  source pixel the same width; other sizes — including `ClawdView`'s 96 pt
  default — stay hard-edged but leave some pixel runs a point wider than others,
  so pass an exact multiple wherever the mascot is a hero element.

## Supplying authorized art

1. Copy the PNGs into this directory using the exact names above, **or**
2. during development, point the app at a working folder without rebuilding:
   `MAIKU_CLAWD_DIR=/path/to/sprites swift run Maiku` — that path is searched
   first, then the app bundle's `Clawd/` subdirectory, then the bundle root.

`ClawdArtwork.isInstalled` is resolved once at launch, so the placeholder badge
disappears on the next run after art is added, not mid-session.

Note for whoever owns packaging: `scripts/build.sh` currently copies
`Resources/Info.plist` plus any SwiftPM resource bundles. Getting this directory
into `Maiku.app/Contents/Resources/Clawd/` needs one `cp -R`, or a
`resources: [.copy(...)]` entry once the art lives under `Sources/MaikuKit/`.

## Attribution

If Maiku is prepared for public distribution, the About screen must state that it
is an independent project and not affiliated with Anthropic, unless the user has
an agreement permitting different language (plan §14).
