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

## Phase 2 — Application foundation ⬜

1. Project library screen: list, create, open, rename, duplicate, delete `.cutlab` files (app documents folder)
2. Save/Open/Import/Export `.cutlab` through native file dialogs (desktop) and the storage access framework (Android)
3. Autosave to a recovery file + "restore unsaved project" prompt on launch
4. Media browser: pick files, store `MediaRef`s with fingerprints, missing-media detection and relink
5. Settings screen (preview quality, cache size, mode default)
6. Landscape tablet layout; keyboard shortcut layer on desktop

## Phase 3 — Media engine ⬜

1. LGPL FFmpeg build in CI for each platform (+ license attribution file)
2. `core/media`: probe (duration, streams, time base, VFR detection), demux, decode, seek-to-frame
3. Android MediaCodec decode path; desktop hardware decode where available
4. Thumbnail strips and waveform peaks in background, cached in SQLite
5. CPU compositor + Flutter `Texture` preview; audio playback with A/V sync
6. `ffigen` bindings and commit of native platform folders

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

## Phase 10 — Release ⬜

Final testing, documentation, signed Android APK/AAB, Windows/Linux/macOS packages, GitHub Release, license decision and public open-source launch.

## Exact next step

**Phase 2, item 1–2:** implement the project library and `.cutlab` save/open on top of `packages/project_format`, including atomic writes and a recovery file, with tests for save → load → equality.
