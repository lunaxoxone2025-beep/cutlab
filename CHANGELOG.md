# Changelog

## CUTLAB 0.5 — Phase 5: timeline playback and audio engine (2026-11-08)

- Play the edited timeline: continuous playback across cuts, gaps and overlapping tracks, photos, next clip prepared ahead, frame-accurate seeking, the cursor follows the sound.
- Real-time audio mixer: every track and clip heard together. Clip, track and master volume, mute and solo, fade in/out, level meters, mono sources at full level.
- Audio-clocked sync without drift on long recordings, plus playback diagnostics (latency, audio gaps, picture lateness, dropped frames, decoders, mixer load).
- Transport under the monitor, Mixer panel (PC) and tab (phone), shortcuts Space / K / L / Shift+Space. Slider drags are heard while dragging and undo in one step.
- Project format v3 (track volume and solo, master volume; older projects open unchanged).
- Tests: native timeline suite, valgrind, benchmarks; integration tests in the real app on Android emulators and on Windows.

## CUTLAB 0.4.2 — Android preview crash: root cause fixed (2026-11-08)

- Fixed the crash when previewing on Android. The audio decoder freed an uninitialised channel layout, and on some phones that crashed the app as soon as the sound started. Found from the crash report of the owner's phone.
- The engine is built so that this kind of mistake cannot crash it again (zero-initialised locals). CI runs valgrind (uninitialised memory, invalid frees, leaks) on every change.
- Diagnostics: the engine activity log is written to disk as it happens and kept for the next start, even if Android ends the app. Reports no longer contain file names or paths.
- The preview pauses when CUTLAB goes to the background.
- Each build is now published as its own release (`cutlab-0.4.N`); earlier builds, including 0.4.20 (the `dev` release), are kept.

## CUTLAB dev 0.4.1 — Android preview crash fix (2026-11-08)

- Fixed the likely cause of the app closing when previewing: decoder memory. Decoder threads now depend on the video size, timeline frames and thumbnails share a memory budget, and the preview queue is limited. A 4K HEVC 10-bit phone video in the editor used up to ~1.6 GB with 8 cores; it now uses ~0.55 GB.
- Hardware video decoding on Android is first tested in a separate process for each kind of video; a decoder that crashes or fails there is not used (software decoding instead).
- Decoding errors no longer end the app: they stop playback and show a message.
- The preview opens in the background and closes the file only when nothing still reads it.
- New: Settings → Diagnostics. Crash reports (native, Java and Android's own records, including out-of-memory kills), device and video decoder list, recent engine activity, copy/save as text. After a crash, CUTLAB says what happened at the next start. If the crash happened during hardware decoding, hardware decoding is turned off.
- Tests: Android emulator lane (API 28 and 34) running the real app, a preview stress test on real-size H.264/HEVC/4K/portrait/long files, and a crash-report test.

## CUTLAB dev 0.4 — Phase 4 (2026-11-08)

- Multitrack timeline: video, image, audio and text tracks; add, move, trim, split on the exact frame, delete/ripple delete, duplicate, copy/cut/paste, photo/title duration.
- Snapping, multi-select, lock/hide/mute tracks, linked clips, separate audio from video, ±1-frame sync nudge, undo/redo for every edit.
- Volume and fades per clip (stored and drawn; audible from Phase 5), waveforms and thumbnails on the timeline.
- Touch gestures on Android; keyboard shortcuts, mouse wheel and drag & drop of files on Windows.
- Timeline monitor showing the exact frame at the playhead and titles.
- `.cutlab` format v2 (v1 projects upgrade automatically).

## CUTLAB dev 0.3 — Phase 3 (2026-11-08)

- Native media engine (C++, FFmpeg 8.1 LGPL, miniaudio): probe, frame-accurate decoding, fast scrubbing, thumbnails, waveforms, hardware decoding with software fallback.
- Playback with audio-driven A/V sync and bounded memory; works on 2-hour recordings.
- Imported media is analysed automatically (duration, resolution, fps, VFR, codecs); real thumbnails on PC and Android.
- Source viewer: play/pause, scrub, frame step, thumbnail strip, audio waveform, decoder statistics.
- Settings: preview quality, hardware decoding, engine info.
- Android APK is arm64-only and needs Android 7.0+; Windows build ships the engine and FFmpeg DLLs.

## CUTLAB dev 0.2 — Phase 2 (2026-11-08)

- Project library with create/open/rename/duplicate/delete, import/export of `.cutlab` files.
- Atomic saves with `.bak`, autosave recovery file and restore prompt after crashes.
- Media import on Android without copying files (persistable URIs, native duration/size/thumbnails) and on PC through native dialogs.
- Missing-media detection and relink; undo/redo; save-on-close; settings screen.
- Personal-use builds: Android APK, Windows and Linux on the `dev` release. macOS dropped.

## Unreleased — Phase 1 (architecture and foundation)

- Repository restructured: CutLab Lite moved to `apps/web/`; root page redirects there.
- New C++ core (`core/`): exact 64-bit tick time arithmetic, rescaling, frame/timecode conversion, C ABI, unit tests.
- New Dart package `packages/project_format`: `.cutlab` v1 model, JSON codec, validation with JSON paths, migration chain, tests.
- New Flutter app foundation (`apps/cutlab`): design tokens, new-project flow, responsive desktop/mobile workspace, beginner/advanced mode switch, widget tests.
- CI: code quality, C++ on Linux/Windows/macOS, Dart and Flutter analysis/tests, Android/Linux/Windows/macOS builds.
- Docs: ARCHITECTURE, ROADMAP, PROJECT_FORMAT, BUILDING, CONTRIBUTING.

## CutLab Lite 1.0 — 2026-11-07

- Browser video editor (PWA) with timeline, trim/split, speed, filters, transitions, text, audio and real-time export.
- Android APK built automatically and published to Releases.
