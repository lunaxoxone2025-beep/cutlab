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

## Phase 3 — Media engine ⬜

1. LGPL FFmpeg build in CI for Android and Windows/Linux (+ attribution file)
2. `core/media`: probe (duration, streams, time base, VFR detection), demux, decode, seek-to-frame; fill `needsProbe` media on PC
3. Android MediaCodec decode path; desktop hardware decode where available
4. Thumbnail strips and waveform peaks in background, cached per device (SQLite)
5. CPU compositor + Flutter `Texture` preview; audio playback with A/V sync
6. `ffigen` bindings to the C ABI

## Phase 4 — Timeline MVP ⬜

Multi-track timeline widget (virtualized), import → add clips, move, trim (frame-accurate), split, delete, ripple delete, snapping, zoom/scroll, markers, track lock/hide/mute, copy/paste/duplicate, undo/redo commands, touch gestures and keyboard shortcuts.

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

**Phase 3, items 1–2:** build LGPL FFmpeg for Android (arm64) and Windows/Linux x64 in CI and implement `core/media` probing behind the C ABI, so imported PC media gets real duration and dimensions and Android probing moves to the shared engine.
