# Changelog

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
