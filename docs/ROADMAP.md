# CUTLAB roadmap

Legend: ✅ done and verified in CI · 🔄 in progress · ⬜ planned. A phase is only marked done when its deliverables are committed **and** the CI checks for them pass.

## Phase 1 — Repository and architecture ✅

- ✅ Inspect and audit the existing repository (`docs/ARCHITECTURE.md` §1)
- ✅ Decide the migration strategy: keep CutLab Lite shipping, build the Flutter + C++ edition next to it
- ✅ Document the architecture and decisions (`ARCHITECTURE.md`)
- ✅ Repository structure: `apps/`, `core/`, `packages/`, `docs/`
- ✅ Define the `.cutlab` format v1 (`PROJECT_FORMAT.md`) with codec, validation, migrations and tests
- ✅ C++ core foundation: exact tick time math + C ABI, tested on Linux/Windows/macOS
- ✅ Flutter application foundation: theme, new-project flow, responsive workspace shell, beginner/advanced switch
- ✅ CI: hygiene, Lite checks, C++ matrix, Dart analysis/tests, Flutter analysis/tests, Android/Linux/Windows/macOS builds

## Phase 2 — Application foundation ✅

- ✅ Project library: list (newest first, damaged files flagged), create, open, rename, duplicate, delete
- ✅ `.cutlab` save with atomic writes and a `.bak` of the previous save; import/export through native dialogs (desktop) and the Storage Access Framework (Android)
- ✅ Autosave of unsaved work to a recovery file (configurable delay, also on app backgrounding) + "restore unsaved changes" prompt
- ✅ Media browser: import video/audio/images; Android keeps persistable `content://` URIs (no copies) and reads duration, size and thumbnails natively; PC references files by path (`needsProbe` until Phase 3)
- ✅ Missing-media detection and relink (same media id, clips stay attached); media still used by clips cannot be removed
- ✅ Undo/redo for project edits, save state indicator, save-on-close
- ✅ Settings: editor mode for new projects, autosave delay, project folder location
- ✅ Installable builds: Android APK, Windows zip, Linux tarball on the rolling `dev` release
- ➡️ Keyboard shortcuts and a dedicated landscape-tablet layout move to Phase 4, where the timeline needs them (tablets already get the desktop layout from 1000 px wide)

## Phase 3 — Media engine ✅ (verified in CI; real-device check pending)

- ✅ FFmpeg 8.1 (LGPL): minimal static build from source for Android arm64 (with MediaCodec) and Linux; prebuilt shared DLLs on Windows x64
- ✅ `core/media`: probe (duration, streams, rotation, frame rate, **VFR detection**, bit depth, audio format), demux by path or Android file descriptor (no copies), frame-accurate and fast seek, RGBA conversion with correct colour matrices
- ✅ Hardware decoding with automatic software fallback: MediaCodec (Android), D3D11VA/DXVA2 (Windows — DXVA2 exercised on the Windows CI runner)
- ✅ Keyframe thumbnail strips and waveform peaks (2-hour file: 24 thumbnails ≈ 20 ms, waveform ≈ 1 s)
- ✅ Player: audio-clock A/V sync (miniaudio), bounded memory, scrubbing, frame stepping; CPU preview in Flutter at 360p–1080p
- ✅ dart:ffi bindings (hand-written; the C ABI is small), probing on import and on open, engine thumbnails, source viewer, preview settings
- ✅ 155 engine checks on Linux and Windows CI (2-hour file, 60/120 fps, VFR, rotation, 10-bit HEVC, A/V timing) + ASan/UBSan locally; Dart unit and widget tests for the integration
- ➡️ Persistent thumbnail/waveform cache (SQLite) moves to Phase 9; Phase 3 caches in memory per session
- ⚠️ Not yet run on the owner's phone/PC: hardware decoding on real devices, preview smoothness at 60/120 fps, audio latency (see `docs/ENGINE.md`, Limitations)

## Phase 4 — Professional timeline ✅ (verified in CI; real-device check pending)

- ✅ Independent video, image, audio and text tracks; `.cutlab` format v2 (image tracks, clip fades, links; v1 upgraded automatically)
- ✅ Add, move (also between tracks), trim start/end, split exactly on a frame, delete, ripple delete (per track), duplicate, copy/cut/paste, photo/title duration — every edit is one undo step
- ✅ Frame grid for 24/25/29.97/30/50/60/120 fps, magnetic snapping, multi-select, lock/hide/mute tracks, linked clips, separate audio, ±1-frame A/V sync nudge
- ✅ Volume (0–200 %) and fades stored and drawn; waveforms and thumbnails from the engine with bounded memory
- ✅ Zoom/scroll; touch gestures on Android (pinch, drag, long-press, trim handles); keyboard shortcuts, mouse wheel and drag & drop of files on Windows
- ✅ Timeline monitor: exact frame at the playhead plus titles
- ✅ Pure-Dart edit operations with unit tests (incl. a 2-hour, 300-clip project); widget tests for add/split/delete/undo/save and the phone layout
- ➡️ Continuous playback of the edited timeline with mixed audio, audible volume/fades/mute, title styling → Phase 5; markers UI → Phase 7; track rename/reorder UI → Phase 5 (see `docs/TIMELINE.md`)
- ⚠️ Not yet tried on the owner's phone/PC

## Phase 5 — Core editing ⬜

Text clips and styling in the preview, audio tracks/fades/volume, transitions, basic effects stack, keyframes with linear/ease/bezier interpolation, crop/resize/rotate/flip/position/opacity.

## Phase 6 — Export ⬜

MP4/H.264 export through platform encoders, resolution/fps/bitrate settings, progress + ETA, cancel, output validation (re-probe), export history. **Milestone: Flutter edition reaches parity with Lite → Lite import path → Lite retired.**

## Phase 7 — Gaming Studio ⬜

Slow-motion and speed ramps, zoom/shake/flash/impact effects, highlight markers, facecam overlay and split-screen, kill counters/HUD overlays, intro/outro templates, presets per genre (FPS, battle royale, Minecraft, racing, sports, survival) with user-defined presets.

## Phase 8 — Advanced features ⬜

Color grading (temperature, tint, exposure, highlights/shadows, curves), LUT import, glow/vignette/grain/chromatic aberration, blend modes, PiP, audio EQ/normalization/ducking/noise reduction, SRT/ASS subtitles, optional local AI (subtitles, silence/scene detection).

## Phase 9 — Optimization ⬜

Proxy workflow, GPU render backends, memory budgets, hardware capability detection and automatic preview quality, long-form tests (2-hour projects), crash-recovery tests.

## Phase 10 — Personal release ⬜

Final testing on the owner's phone and PC, documentation, stable APK and Windows build. No public release (ARCHITECTURE D14).

## Exact next step

1. **Owner device check** of the `dev` build: edit a long recording on the phone and on the PC (add, split, trim, move, undo, save, reopen).
2. **Phase 5, item 1:** native timeline renderer — continuous playback of the edited timeline with all audio tracks mixed (volume, fades, mute audible).
