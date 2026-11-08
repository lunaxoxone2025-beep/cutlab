# CUTLAB architecture

Status: **Phase 1 (foundation)** — November 2026. This document records the decisions taken and why; it is updated whenever a decision changes.

## 1. Starting point (audit of the repository, Phase 1)

| Item | What it is | Verdict |
|---|---|---|
| `apps/web/` (was the repo root) | **CutLab Lite** — a working browser editor: HTML + CSS + one ~1,300-line `app.js`. Single main track, text and audio lanes, trim/split/reorder, speed, filters, 8 transitions, Ken Burns, animated text, undo/redo, IndexedDB autosave, PWA, real-time export through `MediaRecorder`. | **Kept and shipped** as the installable app until the Flutter edition reaches parity (Phase 6). Bug fixes only. |
| `.github/workflows/lite-apk.yml` | Wraps CutLab Lite with Capacitor and publishes `CutLab.apk` to Releases. | Kept, now scoped to `apps/web/**` changes. |
| `android-signing/cutlab.keystore` | Fixed key that signs the Lite APK so updates install over each other. | **Risk** — see §9. |

What Lite proves and what is reused: the interaction model (centered playhead, bottom tool bar, sheet panels), the visual identity (colours and spacing are now design tokens in `apps/cutlab/lib/src/theme.dart`), the effect/transition/text-style catalogue, and the project concepts (clips with in/out/speed, text overlays, audio with fades) that map directly onto the `.cutlab` model.

What Lite cannot become, and why a new engine is needed:

- **Time in floating-point seconds** → drift and off-by-one frames on long timelines.
- **Browser decoding** (`<video>` seeking) → no frame-accurate access, codec support depends on the browser, no hardware encoder control.
- **Export = screen recording in real time** (`MediaRecorder`) → a 2-hour project takes 2 hours, no codec/bitrate control, VP9/WebM on most Android browsers.
- **Media copied into IndexedDB** → duplicates multi-GB recordings and hits storage quotas.
- **One video track**, no keyframes, no proxies, monolithic file.

## 2. Target architecture

```
┌──────────────────────────────── Flutter / Dart (apps/cutlab) ────────────────────────────────┐
│  UI: beginner & advanced workspaces · touch + desktop layouts · design system               │
│  State: immutable Project (packages/project_format) · command-based undo/redo · autosave     │
│  Platform glue: file pickers, storage permissions, preview Texture, background export        │
└───────────────┬──────────────────────────────────────────────────────────────────────────────┘
                │ dart:ffi  →  stable C ABI (core/include/cutlab/cutlab_core.h)
┌───────────────▼──────────────── C++17 core (core/) ──────────────────────────────────────────┐
│ time      exact tick arithmetic (done)                                                       │
│ timeline  evaluates a project at time t → layer list (clips, transforms, effects, keyframes)│
│ media     probe · demux · decode · thumbnails · waveforms · proxies (FFmpeg / OS codecs)     │
│ render    compositor behind a RenderBackend interface (CPU first, then GPU backends)         │
│ audio     mixer · fades · automation · resampling · loudness                                 │
│ export    encode + mux pipeline, progress, cancel, validation                                │
└───────────────┬──────────────────────────────────────────────────────────────────────────────┘
                │ platform abstraction (codec + GPU)
   Android: MediaCodec/MediaExtractor · GLES/Vulkan      Windows: Media Foundation · D3D11/Vulkan
   Linux:   VA-API · OpenGL/Vulkan                       macOS:   VideoToolbox · Metal
```

## 3. Decisions

**D1 — Flutter for UI, C++ for media.** One UI codebase for Android phones, tablets, Windows, Linux and macOS; performance-critical work in portable C++. The UI never touches pixels or samples directly.

**D2 — A narrow C ABI between them.** Flutter calls only `extern "C"` functions with plain types, status codes and out-parameters (`cutlab_core.h`). No C++ exceptions or STL types cross the boundary, so the same library works with `dart:ffi` on every platform and can be called from tests and other front-ends. Bindings will be generated with `ffigen` in Phase 3.

**D3 — Time is an integer.** Every stored time is a signed 64-bit count of ticks at **705,600,000 ticks per second**. Every common frame rate (23.976 → 120 fps, including NTSC 1001-denominator rates) and audio rate (8–192 kHz) lands on an exact integer, so cuts never drift. Source timestamps from containers (variable frame rate included) are rescaled exactly with 128-bit intermediates (`cutlab::rescale`). The Dart package implements the same math (with `BigInt`), and both have tests that pin the same values.

**D4 — `.cutlab` is versioned JSON; media is referenced, never embedded.** Portable, diffable, recoverable by hand. Every load runs the migration chain from the file's version to the current one. See `PROJECT_FORMAT.md`.

**D5 — SQLite is a per-device cache, not the project.** Probe results, thumbnail strips, waveform peaks and proxy locations are keyed by media fingerprint in a local SQLite database. Losing it costs regeneration time, never edits.

**D6 — Immutable project + command undo.** The project is an immutable value tree (structural sharing). Each edit is a command that produces a new project; undo/redo is a stack of snapshots/commands. Autosave writes the current snapshot to a recovery file atomically (write-temp-then-rename).

**D7 — Beginner and advanced modes are views.** `editorMode` only changes which tools and parameters are shown. Both modes read and write the same model, so switching never loses or simplifies data (enforced by a test in `packages/project_format/test/codec_test.dart`).

**D8 — Codec licensing (decision required before Phase 3 ships binaries).** FFmpeg is used **LGPL-only** (no `--enable-gpl`, no `--enable-nonfree`), dynamically linked. Therefore **no libx264/libx265**. H.264/HEVC encoding uses platform encoders (MediaCodec, Media Foundation, VideoToolbox, VA-API); AV1 via SVT-AV1 (BSD) where hardware is absent; VP9 via libvpx (BSD). A software H.264 fallback (OpenH264, BSD with Cisco binary terms) is an open question. HEVC/H.264 patent licensing is the user's/distributor's responsibility and must be stated in release notes.

**D9 — Proxies for long-form footage.** Media above a resolution/bitrate threshold gets a background-generated proxy (short-GOP H.264 or MJPEG at 540p/720p) in the cache directory. Clips keep pointing at the original `MediaRef`; the renderer substitutes the proxy for preview only, and export always uses originals.

**D10 — Rendering behind an interface.** Phase 3 ships a CPU compositor (correctness reference, works everywhere) feeding a Flutter `Texture`. GPU backends (GLES/Vulkan on Android and Linux, D3D11 on Windows, Metal on macOS) arrive in Phase 9 behind the same `RenderBackend` interface, with the CPU path kept as fallback and as the test oracle.

**D11 — AI is optional and local-first.** An `AnalysisProvider` interface (subtitles, silence/scene detection, highlight suggestions) with local implementations first (e.g. whisper.cpp, MIT). Core editing never depends on a network service or paid API.

**D12 — CutLab Lite stays until parity.** Users keep a working app while the new engine is built. Lite receives fixes, not features. It will be retired (with a project import path) once the Flutter edition can import, edit and export MP4 (end of Phase 6).

**D13 — Generated platform folders (temporary).** Until Phase 3 adds native code, `apps/cutlab/{android,linux,windows,macos}` are generated in CI with `flutter create`, which keeps the repository free of template noise. They will be committed when native integration starts.

## 4. Repository layout

```
apps/
  cutlab/            Flutter edition (UI). Platform folders generated until Phase 3.
  web/               CutLab Lite (current installable app, maintenance only)
core/                C++17 engine — CMake project, C ABI in include/cutlab/cutlab_core.h
  include/cutlab/    public headers
  src/               implementation (time.cpp, capi.cpp; media/, render/, … from Phase 3)
  tests/             dependency-free unit tests run by CTest
packages/
  project_format/    Dart: time math, project model, .cutlab codec, validation, migrations
docs/                ARCHITECTURE, ROADMAP, PROJECT_FORMAT, BUILDING
android-signing/     Lite APK signing key (to be moved to a secret, §9)
.github/workflows/   CI, Flutter builds, Lite APK release, Dart auto-format
```

Directories from the master plan that have no code yet (`core/media`, `core/render`, `packages/ui_components`, `assets/…`, `tests/performance`) are **not** created as empty placeholders; each appears in the phase that fills it.

## 5. Module boundaries

| Module | Owns | Must not |
|---|---|---|
| `packages/project_format` | Model, JSON, validation, migrations, time math | Import Flutter or do I/O beyond strings |
| `apps/cutlab` | Widgets, navigation, state, platform channels | Decode media, compute frames |
| `core/time` | Tick/rational arithmetic | Allocate, throw across the C ABI |
| `core/media` (Phase 3) | Probe, decode, thumbnails, proxies | Know about widgets or project UI state |
| `core/render` (Phase 3+) | Compositing a frame from a layer list | Read project files |
| `core/export` (Phase 6) | Encode/mux pipeline | Depend on preview state |

## 6. Performance principles for long-form projects

- Never decode to draw the timeline: thumbnails and waveforms are precomputed at a few resolutions and cached.
- Never load a source into RAM: decode on demand around the playhead with a bounded frame cache.
- Virtualize the timeline: only visible clips build widgets.
- Bound every cache (frames, thumbnails, proxies) with user-configurable limits.
- Long jobs (proxy, waveform, export) run in background isolates/threads with cancellation and progress.

## 7. Security and privacy

- Media and projects stay on the device. No upload without explicit user action.
- Imported files are untrusted: probing runs with size/duration sanity limits; malformed JSON returns a `ProjectFormatException` with the exact path instead of crashing.
- No secrets in the repository (see §9 for the one known exception).

## 8. Testing strategy

- C++: CTest unit tests on Linux, Windows and macOS (CI matrix), warnings as errors.
- Dart: `dart test` for the format package; `flutter test` widget tests for the app.
- Later: golden-frame tests (render a project, compare checksums against the CPU reference), long-form performance tests with generated 2-hour synthetic media, crash-recovery tests.

## 9. Known risks and limitations

1. **Signing key in the repository.** `android-signing/cutlab.keystore` (used by the Lite APK) is public, so anyone could sign an APK that installs as an update of Lite. Fix: move it to an encrypted GitHub Actions secret (requires the repository owner to add the secret) and rotate when the Flutter edition replaces Lite.
2. **FFmpeg distribution** on Android/iOS no longer has a maintained prebuilt kit; we will build LGPL FFmpeg ourselves in CI (Phase 3), which is the largest build-system task in the plan.
3. **Flutter external textures** differ per platform; the preview path is the main Phase 3 integration risk.
4. **Patent-encumbered codecs** (H.264/HEVC) — see D8.
5. **Dart formatting/analysis** cannot be run in every authoring environment; CI is the source of truth and an auto-format workflow keeps style consistent.
