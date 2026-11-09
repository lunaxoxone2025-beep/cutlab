# CUTLAB effects and transitions (Phase 7)

Effects, looks, video fades and transitions are rendered by the engine from the original media. The preview and the export call **the same compositor** (`core/src/media/compositor.cpp`, effect math in `core/src/media/effects.cpp`) with the same parameters, so what the monitor shows is what the file contains. There are no preview-only effects.

## Effects

Every effect has adjustable parameters with a neutral or sensible default. Sizes (blur, sharpen, vignette) are fractions of the picture height, so an effect looks the same in a 360p preview and a 4K export.

| Effect | Type | Parameters (range, default) | What it does |
|---|---|---|---|
| Brightness | `brightness` | amount −1…1 (0) | Adds or removes up to 40 % light |
| Contrast | `contrast` | amount −1…1 (0) | Spreads (up to ×3) or flattens tones around mid-gray |
| Exposure | `exposure` | stops −3…3 (0) | Like opening/closing the lens (in linear light) |
| Gamma | `gamma` | value 0.2…5 (1) | Brightens (>1) or darkens (<1) the mid-tones |
| Highlights | `highlights` | amount −1…1 (0) | Bright half only; negative recovers highlights |
| Shadows | `shadows` | amount −1…1 (0) | Dark half only; positive lifts shadows |
| Saturation | `saturation` | amount −1…1 (0) | −1 = gray, +1 = twice as colourful |
| Vibrance | `vibrance` | amount −1…1 (0) | Boosts dull colours more than strong ones; grays stay gray |
| Temperature | `temperature` | amount −1…1 (0) | Warmer (orange) or cooler (blue) |
| Tint | `tint` | amount −1…1 (0) | Magenta (+) or green (−) |
| RGB | `rgb` | red/green/blue gain 0…2 (1), red/green/blue offset −0.5…0.5 (0) | Per-channel gain and offset |
| Sharpen | `sharpen` | amount 0…3 (0.6), radius 0.0005…0.01 of height (0.0015) | Unsharp mask |
| Blur | `blur` | radius 0…0.05 of height (0.006) | Gaussian-like (three box passes) |
| Vignette | `vignette` | amount 0…1 (0.5), size 0.2…1.5 (0.75), softness 0.05…1 (0.45) | Darker corners, fitted to the clip |
| Grayscale | `grayscale` | amount 0…1 (1) | Rec. 709 luma; partial amounts mix with the colour |
| Black & white | `black_white` | threshold 0…1 (0.5), softness 0…0.5 (0.04) | Two tones (soft edge) |
| Sepia | `sepia` | amount 0…1 (1) | Old-photo brown |
| Colour filter | `filter` | look 0…7 (0), strength 0…1 (1) | Cinematic looks: teal & orange, warm, cool, vintage, noir, vivid, bleach bypass, matte |

A clip can have any number of effects; they apply **in stack order** (top to bottom), each can be switched off (kept in the project, not drawn), reordered or removed. Effects belong to their clip and follow it when it is moved, trimmed, split (both halves keep them), copied or duplicated.

**Looks** (beginner mode, also in advanced mode) are ready-made stacks of the effects above: Cinematic, Vivid, Warm, Cool, Vintage, Noir, Black & white, Sepia, Matte, Game punch. Picking one replaces the clip's effects; "None" removes them.

**Video fades** fade the clip's picture from black at its start and to black at its end (separate from the audio fades).

## Transitions

| Transition | Type | Direction | Needs media beyond the cut |
|---|---|---|---|
| Cross dissolve | `dissolve` | — | yes |
| Dip to black | `dip_black` | — | no |
| Dip to white | `dip_white` | — | no |
| Wipe | `wipe` | left, right, up, down (soft edge) | yes |
| Slide | `slide` | left, right, up, down (the new clip pushes the old one out, eased) | yes |
| Zoom in | `zoom_in` | — | yes |
| Zoom out | `zoom_out` | — | yes |
| Smooth blur | `blur` | — | yes |

Fade in / fade out of a clip are the video fades above.

**Timing.** A transition joins a clip to the clip that ends exactly where it starts on the same track. Its duration is centred on the cut: half before (the outgoing clip continues past its out-point), half after (the incoming clip starts before its in-point). It never changes clip positions or the project length. Limits, applied the same way by the editor and the engine:

- each side takes at most half of its clip, so a clip's two transitions never overlap;
- an overlapping transition stops where the media runs out (the incoming clip's in-point, the outgoing file's end) — it is shortened rather than showing a frozen frame; the editor says when that happens ("Plays 0.70 s … shortened");
- dips use no extra media: the outgoing clip fades to the colour before the cut, the incoming clip fades in after it.

**Sound.** Overlapping transitions cross-fade the two clips' sound with equal-power curves (the level stays steady through the transition); dips keep a straight cut, so the sound never drops.

**Frames.** During a transition both clips keep playing at their own frame rate; every output frame shows the source frame due at that instant (checked frame by frame at 24, 29.97, 30, 60 and 120 fps — see Tests). A transition that is set but cannot play (moved away from its neighbour, or no media for an overlap) is drawn in red on the timeline and is not rendered.

## How a picture is made

For each output frame at time *t* (export: the output frame rate; preview: the project frame rate):

1. Find the top-most visible clip at *t* (and, inside a transition, its neighbour).
2. Decode the source frame displayed at the clip's source time (one decoder per clip, reused across the transition).
3. Fit it into the frame (black bars, rotation, transparent photos over black) in 8-bit RGBA.
4. Apply the clip's effects in order — consecutive per-channel adjustments are folded into one lookup table, consecutive colour matrices into one matrix, so a long chain is still one pass over the pixels; blur/sharpen are separable box filters (large blurs are done on a 2–8× smaller picture and scaled back up); rows are spread over a worker pool.
5. Apply the clip's video fade.
6. Combine with the neighbour for the transition (or fade to black/white for a dip).
7. Export only: convert to the encoder's format and draw the titles on top (the monitor draws titles itself).

Clips without effects, fades or transitions are exported straight from the decoded picture to the encoder format (the Phase 6 path), placed exactly where the compositor would place them. Timelines without any effect, fade or transition play through the Phase 5 preview path unchanged.

**Preview quality.** The preview composes at the project aspect ratio fitted into the preview size (Settings → Preview quality, 360p–1080p). *Fast effects preview* (Settings) composes at 360p for heavy effects on slower devices. Neither changes the export, which always composes at the output size.

## Editor

- **Beginner mode:** looks, four quick sliders (brightness, contrast, saturation, warmth), video fades, transition type and four durations (0.25–2 s), direction for wipes and slides.
- **Advanced mode:** the full effect stack — add any effect (grouped Light / Colour / Detail / Style), every parameter, on/off, move earlier/later, remove, copy the stack to the whole track — frame-exact fades and a transition duration slider with frames shown.
- **Timeline:** transitions are bars across the cut (bow-tie at the cut, grips at both ends): tap to edit, drag a grip to change the length (snapped to frames). Clips with effects show `fx<count>`; video fades show as dark wedges at the top of the clip.
- Desktop: *Effects* tab next to Inspector and Mixer. Phone: the wand button (Effects) in the timeline toolbar opens the effects sheet; tapping a transition opens it too.
- Every change is one undo step; slider drags are rendered live and undo as one step. Everything is saved in the `.cutlab` file (format v4, `docs/PROJECT_FORMAT.md`).

## Performance (measured)

See the measurements section added at the end of Phase 7 below.

## Tests

| Test | What |
|---|---|
| `core/tests/test_effects.cpp` | Every effect checked on a test picture (gray ramp, orange and blue areas) against the untouched picture at known places; defaults neutral; out-of-range values clamped; unknown effects/parameters rejected; effect order; effects per clip; size independence; video fades; every transition and direction at known progress; continuity at 24/29.97/30/60/120 fps on frame-numbered clips (each output frame = the source frame due, none black); preview picture = composed picture; audio RMS across cross-fades and dips; exported files decoded and compared with the composed picture (and with the plain picture), at 24/30/60 fps; sound in an exported cross-fade; a 2-hour timeline with 22 transitions (random positions, preview playback across the 1-hour transition, seeks, memory), and in CI a full 2-hour export of it. Linux, Windows, Android emulators, valgrind. |
| `core/tests/bench_effects.cpp` | Effect and transition cost per frame at 1080p, 1440p and 4K. |
| `packages/project_format/test/effects_test.dart` | The Dart catalogue equals the engine's (read from `effects.cpp`); add/edit/enable/reorder/remove; looks; copy; split; unknown effects kept; video fades; transition rules, limits and handles; v3 files open. |
| `apps/cutlab/test/playback_test.dart` | Plan lines for effects, fades and transitions; undo/redo; save/reload gives the same plan. |
| `apps/cutlab/test/effects_widget_test.dart` | Beginner and advanced panels, phone sheet, transition bar tap, fast preview setting — checked on the plan sent to the renderer and the saved project. |
| `apps/cutlab/integration_test/effects_test.dart` | Real engine in the real app on the Android emulators and Windows: engine catalogue = editor catalogue; preview picture = composed picture; exported frames = composed picture; exported sound = preview mix through a cross-fade; a look and a dip picked in the editor UI are found in the exported video. |

## Limitations (not done yet)

| Item | Status |
|---|---|
| GPU acceleration | **Not implemented.** All effect and transition math runs on the CPU (multi-threaded, one shared worker pool); this CPU path is the only path today. GPU processing is a candidate for the optimisation phase. |
| Keyframes | Effect values are constant over a clip (no animation yet). |
| Titles | Titles are drawn over the composed picture: effects, video fades and dips do not affect them. |
| Transitions between tracks | Only between adjacent clips on the same picture track; picture-in-picture and blend modes are not available. |
| Clip speed | Clips with a speed other than 1 (not editable yet) get no overlap transitions. |
| Bit depth | 10-bit and HDR sources are composed in 8 bits (SDR); clips without effects keep the Phase 6 path. |
| Preview of very heavy stacks | On slow devices, several spatial effects (blur, sharpen) at 1080p preview can drop frames; use Fast effects preview. |
| Device testing | Measured on CI machines and Android emulators only; not yet tried on the owner's phone and PC. |
| Phase 6 hardware encoders | Still **not validated on physical devices** (see `docs/EXPORT.md`). CI runs the software encoders and the emulators' MediaCodec; real-phone and real-GPU encoder speed and behaviour remain unverified. |
