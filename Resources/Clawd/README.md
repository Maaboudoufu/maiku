# Clawd sprites

The Clawd character belongs to Anthropic. Artwork ships here **only** when the
project maintainer has supplied it themselves and confirmed they're authorized
to use it (plan §14 asset rule) — nothing is scraped or traced from anyone
else's work. That includes AI-generated pieces: an image a model produced is
not banned outright, but each one ships only after the maintainer has
individually reviewed it and decided it's authorized to use, the same
authorization bar as anything hand-drawn.

**Current status: `idle`, `listening`, `paused`, and `transcribing` have real,
supplied artwork. `ready`, `organizing`, `complete`, `error`, and
`lmstudio_disconnected` are still the placeholder.** For any state whose files
are not present, `ClawdView` draws an obviously generic pixel creature
carrying a per-state prop, with a "Placeholder art" badge under it — a
stand-in so the state machine, frame timing, and VoiceOver wiring are real and
testable even where the product's actual mascot is still missing.

## Expected files

`ClawdAssetManifest` looks up these exact names. Nothing else in the app knows a
filename, so getting the names right is the whole integration.

| File | State | Frame hold | Status |
| --- | --- | --- | --- |
| `clawd_idle_notebook.png` | idle — standing beside a glowing idea/lightbulb | still | **supplied** |
| `clawd_ready_mic.png` | ready — beside a mic, alert, not recording | still | placeholder |
| `clawd_listening_01.png` … `_08.png` | listening — swinging the mic up and forward | 0.11 s | **supplied** |
| `clawd_paused_01.png` … `_06.png` | paused — standing beside a static pause symbol | 0.14 s | **supplied** |
| `clawd_transcribing_01.png` … `_08.png` | transcribing — sparks of colour trailing off, growing | 0.18 s | **supplied** |
| `clawd_organizing_01.png` … `_03.png` | organizing — sorting cards into folders | 0.22 s | placeholder |
| `clawd_complete.png` | complete — finished page with a checkmark | still | placeholder |
| `clawd_error.png` | error — tangled or unplugged mic cable | still | placeholder |
| `clawd_lmstudio_disconnected.png` | LM Studio disconnected — unplugged computer | still | placeholder |

Thirty files total. Several states shipped with different frame counts, or
poses, than plan §14 first sketched — `listening` needed 8 frames instead of
4, `paused` became a 6-frame loop instead of a single still, `transcribing`
became an 8-frame loop instead of 2, `idle`'s prop became a lightbulb instead
of a notebook — once real art actually arrived. The plan's manifest was
always a *suggested* starting point, not a fixed contract; the filename and
state each frame belongs to is the actual contract (`ClawdAssetManifest`). A
partial set is fine regardless: any frame that fails to resolve falls back to
the placeholder for that frame only, so art can land one state at a time —
which is exactly what happened here.

The `listening` and `transcribing` frames were supplied at 384×512, `paused`
at 512×256, none of them the 64×64 baseline below — all exact multiples of 64
(6×8, 6×8, and 8×4 respectively), which nearest-neighbour scaling handles
without blur (see Format, below) precisely because they're whole multiples.
`idle` was supplied at 520×810, *not* a whole multiple — accepted anyway per
the tolerance the Format section already describes for a hero placement; it
stays hard-edged, just with some pixel runs a point wider than others.

**A supplied PNG can carry a hard-cutout artifact worth checking for**: if an
image started as art on a white canvas and had its background knocked out
by thresholding alpha to fully-opaque/fully-transparent (rather than
preserving a soft edge), the boundary pixels can keep a colour blended toward
white from before the cutout — a pale fringe or halo right at the silhouette
edge, even though alpha there reads as fully opaque. `idle`'s source had
this; fixed by eroding the alpha mask by 1px (`magick src -alpha extract
-morphology Erode Octagon:1 mask.png`, then recomposite with
`-compose CopyOpacity`), which shaves off exactly the contaminated ring
without touching interior colour. Frames with a genuine soft glow baked in on
purpose (`listening`, `paused`, `transcribing`) are a different thing — that
alpha gradient is intentional, not an artifact, and is left alone.

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
