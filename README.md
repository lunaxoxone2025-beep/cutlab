# CUTLAB ✂️

A cross-platform video editor for gaming creators and everyday editing — approachable like a mobile editor, with a professional multi-track workspace for long-form projects.

[![CI](https://github.com/lunaxoxone2025-beep/cutlab/actions/workflows/ci.yml/badge.svg)](https://github.com/lunaxoxone2025-beep/cutlab/actions/workflows/ci.yml)
[![Flutter builds](https://github.com/lunaxoxone2025-beep/cutlab/actions/workflows/flutter-build.yml/badge.svg)](https://github.com/lunaxoxone2025-beep/cutlab/actions/workflows/flutter-build.yml)

## Two editions

| | **CutLab Lite** (available now) | **CUTLAB** (Flutter + C++, in development) |
|---|---|---|
| Where | Android APK · any browser | Android, Windows, Linux, macOS |
| Status | Usable editor | Phase 1 of 10 complete — foundation only, no media editing yet |
| Code | `apps/web/` | `apps/cutlab/`, `core/`, `packages/` |

### 📲 Install CutLab Lite on Android

**[⬇️ Download CutLab.apk](https://github.com/lunaxoxone2025-beep/cutlab/releases/latest/download/CutLab.apk)** — open it on your phone and tap **Install** (allow "install unknown apps" for your browser if Android asks).

Web version: https://lunaxoxone2025-beep.github.io/cutlab/

Lite features: timeline with video, text and audio lanes · trim, split, duplicate, reorder · speed 0.1×–4× · 10 filters and colour adjustments · 8 transitions · Ken Burns motion · animated text with templates · music with fades · 9:16 / 16:9 / 1:1 / 4:5 / 3:4 · undo/redo · autosave · export 480p–1080p. Everything runs on your device; videos are never uploaded.

## CUTLAB (new edition)

- **Flutter** UI shared by phone, tablet and desktop, with **beginner** and **advanced** modes over the same project data.
- **C++ core** for decoding, compositing, audio and export, reached through a small C ABI (`dart:ffi`).
- **Frame-exact time**: every timestamp is an integer (705,600,000 ticks per second).
- **`.cutlab`** versioned JSON project format; media is referenced, never copied.

Development builds (APK/AAB, Linux, Windows, macOS) are attached to each run of the *Flutter builds* workflow. They currently contain the application shell only.

## Documentation

- [Architecture and decisions](docs/ARCHITECTURE.md)
- [Roadmap](docs/ROADMAP.md)
- [Project format](docs/PROJECT_FORMAT.md)
- [Building](docs/BUILDING.md)
- [Contributing](CONTRIBUTING.md) · [Changelog](CHANGELOG.md)

## License

Not yet chosen — see the open decision in `docs/ARCHITECTURE.md` (D8 covers codec licensing). Until a license is added, all rights are reserved by the repository owner.
