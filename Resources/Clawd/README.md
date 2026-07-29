# Clawd sprites

The Clawd character belongs to Anthropic. Artwork ships here **only** when the
project maintainer has supplied it themselves and confirmed they're authorized
to use it (plan §14 asset rule) — nothing is scraped, traced, downloaded, or
model-generated into a lookalike.

**Current status: `listening` has real, supplied artwork (`clawd_listening_01.png`
… `_08.png`). Every other state is still the placeholder.** For any state whose
files are not present, `ClawdView` draws an obviously generic pixel creature
carrying a per-state prop, with a "Placeholder art" badge under it — a stand-in
so the state machine, frame timing, and VoiceOver wiring are real and testable
even where the product's actual mascot is still missing.

## Expected files

`ClawdAssetManifest` looks up these exact names. Nothing else in the app knows a
filename, so getting the names right is the whole integration.

| File | State | Frame hold | Status |
| --- | --- | --- | --- |
| `clawd_idle_notebook.png` | idle — holding a small notebook | still | placeholder |
| `clawd_ready_mic.png` | ready — beside a mic, alert, not recording | still | placeholder |
| `clawd_listening_01.png` … `_08.png` | listening — holding the mic, waving, sound waves | 0.11 s | **supplied** |
| `clawd_paused.png` | paused — sitting/sleeping beside a pause symbol | still | placeholder |
| `clawd_transcribing_01.png`, `_02.png` | transcribing — typing at a tiny terminal | 0.25 s | placeholder |
| `clawd_organizing_01.png` … `_03.png` | organizing — sorting cards into folders | 0.22 s | placeholder |
| `clawd_complete.png` | complete — finished page with a checkmark | still | placeholder |
| `clawd_error.png` | error — tangled or unplugged mic cable | still | placeholder |
| `clawd_lmstudio_disconnected.png` | LM Studio disconnected — unplugged computer | still | placeholder |

Nineteen files total (`listening` needed 8, not the 4 first sketched, once real
art actually arrived at that frame count). A partial set is fine: any frame
that fails to resolve falls back to the placeholder for that frame only, so art
can land one state at a time — which is exactly what happened here.

The `listening` frames were supplied at 512×512, not the 64×64 baseline below —
an exact 8× multiple, which nearest-neighbour scaling handles without blur (see
Format, below) precisely because it's a whole multiple.

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

`ClawdArtwork.isFullyInstalled(_:)` is resolved once per state (cached by that
state's frame list), so a given state's placeholder badge disappears on the
next run after that state's art is added, not mid-session — and installing one
state's art never hides another state's badge.

`scripts/build.sh` already copies this whole directory into
`Maiku.app/Contents/Resources/Clawd/` on every build — dropping PNGs in here is
the entire integration step, nothing else to wire up.

## Attribution

If Maiku is prepared for public distribution, the About screen must state that it
is an independent project and not affiliated with Anthropic, unless the user has
an agreement permitting different language (plan §14).
