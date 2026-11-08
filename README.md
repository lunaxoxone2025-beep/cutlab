# CUTLAB ✂️

Personal video editor for Android and PC (Windows/Linux) — approachable like a mobile editor, with a professional multi-track workspace for long gameplay recordings. Private project; not published or distributed.

[![CI](https://github.com/lunaxoxone2025-beep/cutlab/actions/workflows/ci.yml/badge.svg)](https://github.com/lunaxoxone2025-beep/cutlab/actions/workflows/ci.yml)
[![Flutter builds](https://github.com/lunaxoxone2025-beep/cutlab/actions/workflows/flutter-build.yml/badge.svg)](https://github.com/lunaxoxone2025-beep/cutlab/actions/workflows/flutter-build.yml)

## Install

| | **CUTLAB** (new, in development) | **CutLab Lite** (current everyday editor) |
|---|---|---|
| Android | [`CUTLAB.apk`](https://github.com/lunaxoxone2025-beep/cutlab/releases/download/dev/CUTLAB.apk) | [`CutLab.apk`](https://github.com/lunaxoxone2025-beep/cutlab/releases/latest/download/CutLab.apk) |
| Windows | [`CUTLAB-windows-x64.zip`](https://github.com/lunaxoxone2025-beep/cutlab/releases/download/dev/CUTLAB-windows-x64.zip) → unzip → `cutlab.exe` | — |
| Linux | [`CUTLAB-linux-x64.tar.gz`](https://github.com/lunaxoxone2025-beep/cutlab/releases/download/dev/CUTLAB-linux-x64.tar.gz) | — |

Both Android apps can be installed side by side. Newer builds install over older ones and keep projects. If the repository is private, open the links while signed in to GitHub.

## Status

**CUTLAB** — Phase 3 of 10: project library with autosave/recovery, media import without copying files, and a native FFmpeg media engine (frame-accurate preview with synced audio, thumbnails, waveforms, hardware decoding). Timeline editing and export arrive in Phases 4–6 ([roadmap](docs/ROADMAP.md), [engine](docs/ENGINE.md)). Until then, **CutLab Lite** (`apps/web/`) remains the editor for finished videos.

Android build: arm64, Android 7.0 or newer.

## Code

- `apps/cutlab/` — Flutter app (UI, storage, platform glue; native Android code in `platform_overlay/`)
- `core/` — C++17 engine (exact frame time math; media engine from Phase 3)
- `packages/project_format/` — `.cutlab` format: model, codec, validation, migrations
- `apps/web/` — CutLab Lite

Docs: [Architecture](docs/ARCHITECTURE.md) · [Roadmap](docs/ROADMAP.md) · [Project format](docs/PROJECT_FORMAT.md) · [Building](docs/BUILDING.md) · [Changelog](CHANGELOG.md)
