# Changelog

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
