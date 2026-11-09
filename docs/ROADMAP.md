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

### 0.4.1 — Android preview crash (fixed before Phase 5)

- ✅ Investigation and fixes: decoder memory (main suspect), isolated hardware decoder test, exception safety, background open, descriptor lifetime (`docs/ANDROID_PREVIEW_CRASH.md`)
- ✅ Diagnostics: native/Java crash reports, Android exit records, device and decoder information, engine activity log (Settings → Diagnostics)
- ✅ Android emulator tests (API 28/34) inside the real app; stress test; crash-report test
- ⚠️ Not yet confirmed on the owner's phone

## Phase 5 — Timeline playback & audio engine ✅ (verified in CI and on emulators; owner device check pending)

- ✅ Native timeline renderer: continuous playback across cuts, gaps, overlaps, photos; next clip prepared ahead; frame-accurate seeks; cursor follows the audio clock
- ✅ Real-time mixer: all audible clips and tracks, clip/track/master gain, mute, solo, fades, mono at full level, clipping guard, level meters
- ✅ Audio-clocked A/V sync (no drift on long files), playback diagnostics
- ✅ Transport under the monitor, Mixer panel/tab, Space/K/L/Shift+Space, live slider changes as one undo step
- ✅ Tests: 127-check native timeline suite (Linux, Windows, emulators, valgrind), Dart/widget tests, integration test in the real app on Android emulators and Windows
- ➡️ Moved to later phases: picture compositing/transitions/effects/keyframes, title styling, clip speed (they were listed here before the phase was redefined)
- ⚠️ Not yet measured on the owner's phone and PC


## Phase 6 — Export ✅ (verified in CI, on Android emulators and Windows; owner device check pending)

- ✅ Whole-project rendering from the original files: top-most visible clip, letterbox, rotation, photos, titles, gaps, exact project length; the Phase 5 mixer offline (volume, mute, solo, fades, master); constant frame rate with the right source frame for every output frame
- ✅ H.264, HEVC, VP9, AV1 in MP4/MOV/WebM/MKV; hardware encoders (MediaCodec, NVENC, Quick Sync, AMF, Media Foundation) with automatic fallback to software (OpenH264, kvazaar, libvpx, SVT-AV1); all LGPL/BSD
- ✅ 480p–4K, 24/30/60/120 fps, quality presets, manual bitrate, encoder effort, keyframes, audio bitrate, threads; size estimate
- ✅ Export screen: progress, speed, time left, pause/resume, stop (nothing left behind), errors, retry in software, the finished file read back and compared with the settings
- ✅ Android: hardware encoders tested in a separate process, background export (foreground service, wake lock), pause when hot, gallery (Movies/CUTLAB); Windows: save dialog, GPU first, Show file
- ✅ Tests: native export suite (every picture/sound check against the sources, all formats, sizes, rates, cancel, broken media, 2-hour export) + independent ffprobe check of every file, Dart/widget tests, integration tests in the real app on Android emulators and Windows
- ➡️ Not in this phase: resuming an export after the app was closed, compositing/effects/transitions (Phases 7–8), HDR tone mapping, export history list
- ⚠️ **Outstanding:** hardware encoder performance and behaviour on physical devices are not verified. CI ran the software encoders, the Windows runner's Media Foundation encoders and the emulators' MediaCodec only; no claim is made about real-phone or real-GPU encoding speed until it is tested on the owner's phone and PC

## Phase 7 — Effects and transitions ✅ (verified in CI, on Android emulators and Windows; owner device check pending)

- ✅ 18 effects with parameters and defaults: brightness, contrast, exposure, gamma, highlights, shadows, saturation, vibrance, temperature, tint, RGB, sharpen, blur, vignette, grayscale, black & white, sepia, colour filter (8 cinematic looks); 10 ready-made looks
- ✅ Transitions: cross dissolve, dip to black/white, wipe and slide (4 directions), zoom in/out, smooth blur; video fade in/out; equal-power audio cross-fades
- ✅ One compositor for preview and export (same code, same parameters, from the original media); duration centred on the cut and limited by the media handles (no frozen or black frames)
- ✅ Editor: beginner (looks, quick sliders, simple transitions) and advanced (full stack, every parameter, reorder, on/off, frame-exact timing) on desktop and phone; transition bars on the timeline (tap to edit, drag to resize); undo/redo; project format v4 (older projects unchanged)
- ✅ Fast effects preview (export unaffected); effect math on the CPU, multi-threaded (no GPU path yet)
- ✅ Tests on rendered pictures: every effect and transition, continuity at 24–120 fps, preview = composed picture = exported frame, audio continuity, 2-hour timeline and export with effects, valgrind; Dart/widget tests; integration tests in the real app on Android emulators and Windows
- ⚠️ Not yet measured on the owner's phone and PC

## Phase 8 — Gaming Studio ⬜

Slow-motion and speed ramps, zoom/shake/flash/impact effects, highlight markers, facecam overlay and split-screen, kill counters/HUD overlays, intro/outro templates, presets per genre (FPS, battle royale, Minecraft, racing, sports, survival) with user-defined presets.

## Phase 9 — Advanced features ⬜

Curves, LUT import, glow/grain/chromatic aberration, effect keyframes, blend modes, PiP, audio EQ/normalization/ducking/noise reduction, SRT/ASS subtitles, optional local AI (subtitles, silence/scene detection).

## Phase 10 — Optimization ⬜

Proxy workflow, GPU render backends (effects and transitions included), memory budgets, hardware capability detection and automatic preview quality, long-form tests (2-hour projects), crash-recovery tests.

## Phase 11 — Personal release ⬜

Final testing on the owner's phone and PC, documentation, stable APK and Windows build. No public release (ARCHITECTURE D14).

## Exact next step

1. **Owner device check** of Phases 6 and 7 (still outstanding: hardware encoders have only run in CI and on emulators): export a long COD Mobile / Minecraft recording at 1080p60 (H.264 and HEVC) on the phone and on the PC, with and without a look and a few transitions; note the speed, the encoder used, whether the preview keeps up, and whether the phone gets hot.
2. **Phase 8:** Gaming Studio.
