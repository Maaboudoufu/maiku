# Clawd sprites

The Clawd character belongs to Anthropic. Artwork ships here **only** when the
project maintainer has supplied it themselves and confirmed they're authorized
to use it (plan §14 asset rule) — nothing is scraped or traced from anyone
else's work. That includes AI-generated pieces: an image a model produced is
not banned outright, but each one ships only after the maintainer has
individually reviewed it and decided it's authorized to use, the same
authorization bar as anything hand-drawn.

**Current status: `idle`, `listening`, and `paused` have real, supplied
artwork. `ready`, `complete`, `error`, and `lmstudio_disconnected` are still
the placeholder.** For any state whose files are not present, `ClawdView`
draws an obviously generic pixel creature carrying a per-state prop, with a
"Placeholder art" badge under it — a stand-in so the state machine, frame
timing, and VoiceOver wiring are real and testable even where the product's
actual mascot is still missing.

**`transcribing` and `organizing` are not on this list on purpose — they no
longer use supplied art at all.** Both states render `ProcessingSprite`, a
small SwiftUI view in `ClawdView.swift` that draws three `PixelCorner` blocks
bouncing in a wave, computed from the frame clock the same way every other
piece of chrome in this design system already animates. Two different
AI-supplied contact sheets were tried for these two states and both needed
re-registration to stop visibly jittering (see the frame-registration note
below) — a procedurally drawn shape has no source photo to mis-register, so
this class of bug cannot recur here. `ClawdAssetManifest.entry(for:)` returns
an empty `Entry` for both states, and `ClawdView` skips the "Placeholder art"
badge for them entirely: this is finished chrome, not a stand-in for missing
Clawd artwork, so it isn't subject to the artwork-authorization rule above at
all — nothing here is Clawd's likeness.

## Expected files

`ClawdAssetManifest` looks up these exact names. Nothing else in the app knows a
filename, so getting the names right is the whole integration.

| File | State | Frame hold | Status |
| --- | --- | --- | --- |
| `clawd_idle_notebook.png` | idle — standing beside a glowing idea/lightbulb | still | **supplied** |
| `clawd_ready_mic.png` | ready — beside a mic, alert, not recording | still | placeholder |
| `clawd_listening_01.png` … `_07.png` | listening — swinging the mic up and forward | 0.11 s | **supplied** |
| `clawd_paused.png` | paused — standing beside a glowing pause symbol | still | **supplied** |
| *(none — `ProcessingSprite`)* | transcribing — three blocks bouncing in a wave | code-drawn | n/a |
| *(none — `ProcessingSprite`)* | organizing — three blocks bouncing in a wave | code-drawn | n/a |
| `clawd_complete.png` | complete — finished page with a checkmark | still | placeholder |
| `clawd_error.png` | error — tangled or unplugged mic cable | still | placeholder |
| `clawd_lmstudio_disconnected.png` | LM Studio disconnected — unplugged computer | still | placeholder |

Nine files total. Several states shipped with different frame counts, or
poses, than plan §14 first sketched — `listening` needed 7 frames instead of
4, `idle`'s prop became a lightbulb instead of a notebook — once real art
actually arrived. `paused` shipped as a still, not the plan's sketched
animation: the first supplied `paused` art was a 6-frame loop, later replaced
outright with a single still in the same glowing style as `idle` and the app
icon, once it became clear a "waiting" pose had no motion worth animating;
its pause-symbol badge was then scaled up roughly 1.5× relative to the
character, since the originally supplied proportion read as too small at
typical display sizes. The plan's manifest was always a *suggested* starting
point, not a fixed contract; the filename and state each frame belongs to is
the actual contract (`ClawdAssetManifest`). A partial set is fine regardless:
any frame that fails to resolve falls back to the placeholder for that frame
only, so art can land one state at a time — which is exactly what happened
here.

**`listening`'s original 8th frame (the mic being set down) was dropped.** A
sequence meant to loop continuously while the mic is live should never
contain a one-way "put it away" beat — playing that frame on every loop
iteration reads as the character repeatedly fumbling the mic. Cut down to the
7-frame raise-and-hold cycle that actually loops cleanly.

The `listening` frames were supplied at 384×512, not the 64×64 baseline
below — an exact multiple of 64 (6×8), which nearest-neighbour scaling
handles without blur (see Format, below) precisely because it's a whole
multiple. `idle` was supplied at 520×810 and `paused` at 384×256, neither a
whole multiple — accepted anyway per the tolerance the Format section already
describes for a hero placement; both stay hard-edged, just with some pixel
runs a point wider than others.

None of this supplied art is square, which exposed a real `ClawdView` bug:
`.resizable()` alone stretches its source to exactly fill whatever frame it's
given, distorting anything non-square rather than scaling it proportionally.
Fixed with `.aspectRatio(contentMode: .fit)` ahead of the frame — the one
place every state's sprite renders through, so it fixed every state at once.

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
purpose (`listening`, `paused`) are a different thing — that alpha gradient
is intentional, not an artifact, and is left alone.

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
