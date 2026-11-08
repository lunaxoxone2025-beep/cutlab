# CUTLAB timeline (Phase 4)

## What works

### Tracks
- Independent **video**, **image**, **audio** and **text** tracks. Clips only go on tracks of their kind (video files → video tracks, photos → image tracks, sound → audio tracks, titles → text tracks). The editor creates a new track automatically when a spot is taken.
- Stacking: higher picture tracks cover lower ones (titles on top). The monitor shows the top-most visible picture.
- Per-track **lock** (no edits possible), **hide** (picture not shown), **mute** (heard in playback since Phase 5), rename/reorder via the model, **add track** (advanced mode toolbar).

### Clip editing (every operation is one undo step)
| Operation | How |
|---|---|
| Add media | ＋ button on a file in Media (at the playhead) · desktop: drag the file onto the timeline · Windows: drop files from Explorer (imported without copying, analysed, then placed one after another) |
| Add title | **T** button in the timeline toolbar |
| Select | tap/click · multi-select: Ctrl/Shift-click, or the multi-select toggle on touch · Ctrl+A |
| Move | drag a selected clip (mouse: drag any clip) · long-press a clip on touch to grab it at once · up/down to another track of the same kind · several selected clips move together |
| Trim | drag the white edges of a selected clip (start or end) |
| Split | **S** / Ctrl+B / ✂ — selected clips, or everything under the playhead when nothing is selected |
| Delete / ripple delete | Del / Shift+Del (ripple closes the gap on that track) |
| Duplicate, copy, cut, paste | Ctrl+D, Ctrl+C, Ctrl+X, Ctrl+V (paste at the playhead) |
| Photo/title duration | inspector − / + (1 s steps) or trim the end edge |
| Volume | inspector slider 0–200 % (several selected clips at once) |
| Fade in / out | inspector sliders (shown as dark ramps on the clip) |
| Separate audio | moves a video's sound to an audio track, **linked** to the video and the video clip muted |
| Link / unlink | advanced toolbar; linked clips move, trim, split, copy and delete together |
| A/V sync | unlink, then shift audio (or video) by single frames: inspector ±1 frame or Alt+←/→ |
| Undo / redo | Ctrl+Z / Ctrl+Y (or Ctrl+Shift+Z), toolbar buttons |

Rules the editor enforces (tested):
- Every position is snapped to the project frame grid (24, 25, 29.97, 30, 50, 60, 120 fps), so a split is always exactly between two frames.
- Clips never overlap on a track and are **never overwritten**: dropping a clip on another moves it to a free track instead.
- Trims stop at the start/end of the source file, at the neighbouring clip and at one frame minimum.
- Locked tracks cannot be changed by any operation.
- Linked clips stay in sync through move, trim, split, copy/paste and delete.
- Media that is still being analysed cannot be placed until its duration is known.

### Navigation
- Zoom: pinch, Ctrl+wheel, +/−, toolbar zoom buttons, "fit project". From ~2 hours per screen to ~10 px per frame.
- Scroll: drag empty space, mouse wheel (Shift+wheel scrolls tracks vertically).
- Playhead: tap/drag the ruler, ←/→ one frame, Shift+←/→ one second, ↑/↓ previous/next clip edge, Home/End.
- **Magnetic snapping** (toggle with N or the ruler button): clip edges, the playhead, markers and 0, within 10 px. A yellow guide shows where it snapped.

### Display
- Video/photo clips show **thumbnails** from the media engine; audio clips show their **waveform** (scaled by the clip volume). Both are generated in the background once per file per session and are bounded in size (≤ 180 thumbnails, ≤ ~4000 waveform buckets per file), so 2-hour recordings cost the same memory as short ones.
- Only clips in the visible time range are drawn, in one canvas.
- **Timeline monitor**: the exact frame at the playhead (fast keyframe frames while scrubbing or dragging, the accurate frame as soon as you stop) plus the titles active at that time.

### Saving
All edits are part of the `.cutlab` project (format **v2**: image tracks, clip fades and links; v1 files are upgraded automatically on open). Autosave/recovery and save-on-close from Phase 2 cover the timeline.

## Not done yet (planned, clearly not simulated)

| Item | Status |
|---|---|
| ~~Continuous playback with all tracks mixed~~ | **Done in Phase 5**, see `docs/PLAYBACK.md`. |
| ~~Volume, fades and track mute audible~~ | **Done in Phase 5** (also track volume, solo, master volume). Export: Phase 6. |
| Title styling (font, colour, position, animation) | Phase 5. Titles show as plain centred text in the monitor. |
| Speed changes, transitions, effects, keyframes | Phase 5 (the model already stores them). |
| Ripple delete across all tracks / ripple trim | Ripple delete works per track; full ripple editing is planned with the timeline renderer. |
| Markers UI | The model and snapping support markers; adding them from the UI comes in Phase 7 (highlight markers). |
| Track rename/reorder from the UI | The operations exist and are tested; UI menu comes with the Phase 5 track panel. |

## Code
- Edit operations: `packages/project_format/lib/src/timeline.dart` (pure Dart, tested in `test/timeline_test.dart`).
- UI: `apps/cutlab/lib/src/timeline/` — `timeline_view.dart` (gestures), `timeline_painter.dart` (drawing), `timeline_state.dart` (zoom/scroll/selection), `timeline_actions.dart` (commands), `timeline_toolbar.dart`, `clip_inspector.dart`, `program_monitor.dart`, `timeline_assets.dart` (thumbnails/waveforms).
