# CUTLAB ✂️

Personal video editor for Android and PC (Windows/Linux) — approachable like a mobile editor, with a professional multi-track workspace for long gameplay recordings. Private project; not published or distributed.

[![CI](https://github.com/lunaxoxone2025-beep/cutlab/actions/workflows/ci.yml/badge.svg)](https://github.com/lunaxoxone2025-beep/cutlab/actions/workflows/ci.yml)
[![Flutter builds](https://github.com/lunaxoxone2025-beep/cutlab/actions/workflows/flutter-build.yml/badge.svg)](https://github.com/lunaxoxone2025-beep/cutlab/actions/workflows/flutter-build.yml)

## Install (private: sign in to GitHub as the owner)

The repository and every build are private. New builds are never published:

- **Latest builds:** [Releases](https://github.com/lunaxoxone2025-beep/cutlab/releases) — each build is a **draft** `cutlab-<version>` (CUTLAB) or `lite-v<version>` (CutLab Lite), visible only to the owner. Open the newest draft and download `CUTLAB.apk`, `CUTLAB-windows-x64.zip` (unzip → `cutlab.exe`) or `CUTLAB-linux-x64.tar.gz`.
- **Also:** [Actions → Flutter builds](https://github.com/lunaxoxone2025-beep/cutlab/actions/workflows/flutter-build.yml) → a run → *Artifacts* (`cutlab-android`, `cutlab-windows-x64`, `cutlab-linux-x64`; kept 90 days).
- **Earlier builds** stay where they were, e.g. 0.4.20 in the [`dev`](https://github.com/lunaxoxone2025-beep/cutlab/releases/tag/dev) release and `cutlab-0.4.21` … `cutlab-0.7.56`.

Both Android apps can be installed side by side. Newer builds install over older ones and keep projects.

## Status

**CUTLAB** — Phase 7 of 11: project library with autosave/recovery, media import without copying files, native FFmpeg media engine, multitrack timeline, real-time timeline playback with an audio mixer, video export (H.264/HEVC/VP9/AV1, 480p–4K, 24–120 fps, hardware or software encoding), and effects, looks and transitions rendered identically in the preview and the export ([roadmap](docs/ROADMAP.md), [effects](docs/EFFECTS.md), [export](docs/EXPORT.md), [playback](docs/PLAYBACK.md), [timeline](docs/TIMELINE.md), [engine](docs/ENGINE.md)).

Android build: arm64, Android 7.0 or newer.

## Code

- `apps/cutlab/` — Flutter app (UI, storage, platform glue; native Android code in `platform_overlay/`)
- `core/` — C++17 engine (exact frame time math; media engine from Phase 3)
- `packages/project_format/` — `.cutlab` format: model, codec, validation, migrations
- `apps/web/` — CutLab Lite

Docs: [Architecture](docs/ARCHITECTURE.md) · [Roadmap](docs/ROADMAP.md) · [Project format](docs/PROJECT_FORMAT.md) · [Building](docs/BUILDING.md) · [Changelog](CHANGELOG.md)
