# Contributing to CUTLAB

1. Read `docs/ARCHITECTURE.md` and the current phase in `docs/ROADMAP.md`.
2. Keep modules independent: UI in `apps/cutlab`, format/model in `packages/project_format`, media work in `core/`.
3. Store time as integer ticks (`ticksPerSecond = 705600000`), never as floating-point seconds.
4. Every change to the `.cutlab` layout follows the versioning rules in `docs/PROJECT_FORMAT.md`.
5. No placeholder controls: a button exists only when its feature works. Unbuilt areas say which phase delivers them.
6. Add tests with every significant change; CI must be green before merging.
7. Never commit secrets, generated binaries (`.apk`, `.exe`, …) or media files.
8. Commit messages: imperative summary line (`core: add frame-accurate rescale`), body explaining *why* when it is not obvious.
9. Dart: `dart format --line-length 140`. C++: C++17, warnings as errors, no exceptions across the C ABI.
