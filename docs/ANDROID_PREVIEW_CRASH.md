# Android preview crash — investigation and fixes (CUTLAB 0.4.1)

**Report (owner, Nov 2026):** the Android APK closes itself when previewing a video.

No crash log from the phone was available, and the crash could not be run on
the owner's phone from here. The investigation therefore covered the whole
preview pipeline, reproduced it on Android emulators and measured memory.
Everything that can end the app was fixed, and diagnostics were added so that
if CUTLAB still closes, the next start shows exactly where and why.

## What the investigation found

| Area | Finding | Change |
|---|---|---|
| **Decoder memory** (most likely cause) | Every decoder started up to 8 frame threads whatever the picture size, and each frame thread keeps a decoded picture in flight. Previewing also starts other decoders at the same time: the timeline monitor (one per playhead position) and thumbnails. With 8 CPU cores, the editor's normal workload on a **4K HEVC 10-bit phone recording peaked at 1642 MB** (1080p60 H.264: 528 MB). Android ends apps that use that much memory without any error message — "the app closes itself". | Threads depend on the picture size (4K: 3, 1440p: 4, smaller: up to 6). Single-frame decodes (monitor, thumbnails) use 2 slice threads and share a budget of one 4K picture at a time. The player's frame queue is limited to 48 MB. Same workload now: **544 MB (4K HEVC 10-bit), 193 MB (1080p60)**. |
| **Hardware decoders (MediaCodec)** | Hardware decoders are vendor code. FFmpeg copies their output with stride/layout values reported by the phone, without checking them against the buffer size. A wrong value from a phone's decoder crashes the process. This cannot be caught inside the app. | Each kind of video (codec, bit depth, size, frame rate) is first decoded in a separate process (`:hwprobe`). If the decoder crashes, hangs or fails there, that kind of video uses software decoding. The editor keeps running. Results are cached per app version. Settings → Diagnostics → *Test hardware decoding again* clears them. |
| **Exceptions on decoder threads** | The player's video and audio threads only caught `MediaError`. Any other C++ exception (out of memory, an internal error) left the thread and **aborted the whole app**. | All exceptions are caught. Playback stops at that point and the viewer shows *"This video could not be decoded further: …"*. Every player call in the C API is guarded. |
| **UI thread** | Opening a player (reading the file, starting the decoder) ran on the Flutter UI thread. | Players are opened in a background isolate. |
| **File descriptors** | Android media is read through a file descriptor. Closing the viewer closed the descriptor while thumbnails could still be reading it. The number could then be reused by another file. | A descriptor is closed only when no engine call still uses it. |
| **Frame memory in Dart** | Every new frame was copied, even while the previous one was still being uploaded to the GPU. | Frames are fetched only when the previous one has been shown. |
| Software decoding, FFmpeg 8.1, A/V sync | No crash under AddressSanitizer or ThreadSanitizer in a stress test that runs the player, monitor frames and thumbnails concurrently on real-size files. TSan only reported known false positives inside FFmpeg's own threading. | — |
| Surfaces/textures | CUTLAB does not use Android surfaces or textures for preview: frames are RGBA images drawn by Flutter. There is no surface lifecycle to get wrong. | — |
| Broken or unsupported files | Truncated files, random bytes and AV1 without a decoder fail with a message. Verified on emulators. | — |

The memory figures come from the engine built for Linux with the CPU count set to 8, running preview + 2 monitor decoders + thumbnails at once. Android figures appear in the emulator test log (`memory …` lines).

## What is not proven

- The exact cause on the owner's phone is **not confirmed**: no crash log from the phone was available. Excessive memory use is the most likely cause, a vendor hardware decoder the second. Both are fixed. If CUTLAB still closes, the next start shows a report (see below).
- Emulators use Google's software MediaCodec decoders. A phone's own hardware decoders (Qualcomm, MediaTek, Exynos…) were not run. The separate test process exists for exactly that reason.
- The arm64 APK itself was not run: emulators in CI are x86_64. The same engine code and app code are built for both.

## If CUTLAB closes again

At the next start CUTLAB shows *"CUTLAB closed unexpectedly"* with a **Details** button (also available from Settings → Diagnostics). The report contains:

- **Native crash** (engine, FFmpeg, MediaCodec): signal, fault address, thread, registers, a backtrace with library offsets, memory (RSS, peak, free memory), the number of hardware decoders open, and the last 64 engine events (e.g. `decoder hevc_mediacodec hevc 3840x2160 10-bit threads=… hw=1 rss=…MB`, `player open …`, FFmpeg warnings).
- **Java/Kotlin crash**: stack trace and Java heap use.
- **Android's record** (Android 11+): crashes, native crashes and low-memory kills with memory use at the end. These include crashes from older CUTLAB versions, so after installing 0.4.1 the original crash may be listed. For native crashes, the readable parts of the system crash record are included.
- **Device:** model, Android version, CPU count, RAM, and every video decoder (hardware or software, maximum size, colour formats). Also the results of the hardware decoding tests and recent Dart/Flutter errors.

If the crash happened while a hardware decoder was open, hardware decoding is switched off automatically. The notice says so, and it can be turned on again in Settings.

**Copy** or **Save** puts the whole report into one text file.

Backtrace offsets in `libcutlab_core.so` can be resolved with the unstripped library from the build's `cutlab-android-symbols` artifact:

```
llvm-addr2line -f -C -e libcutlab_core-arm64-v8a.so 0x<offset>
```

## Tests added

| Test | Where | What it checks |
|---|---|---|
| `cutlab_stress_preview` | CI Linux (real-size media), CI Windows, Android emulators | Players opened/closed quickly (half of them closed after 5 ms), fast and accurate seeks, seeking past the end, monitor frames and thumbnails on other threads at the same time, bad inputs. H.264 1080p30/60, HEVC 1080p60, HEVC 10-bit 4K, portrait phone clip (rotation flag), 10-minute and 2-hour files, VFR, audio, image. |
| `cutlab_crash_report_tests` | CI Linux, Android emulators | A child process crashes on purpose (invalid memory access, abort). The report must contain the signal, device, memory, backtrace and engine activity, and the process must still end with the original signal. |
| `integration_test/preview_pipeline_test.dart` | Android emulators API 28 and 34 (`.github/workflows/android-tests.yml`) | Runs inside the real app: device and decoder list; the hardware test process; playback with hardware and software decoding for every file; frames, thumbnails and waveforms; 25 quick open/close cycles; broken files; and **the full editor**: 4 recordings on the timeline (monitor, thumbnails, waveforms) while previewing 4K and 1080p60 files, with memory figures. |
| Dart unit/widget tests | CI | Crash reports are collected once and kept in the history. Hardware decoding is turned off after a crash during hardware decoding, and stays on after a software one. Low-memory kills are reported; a crash in the hardware test process is only recorded. The crash notice and Diagnostics screen work. A video whose hardware test failed plays in software. A file is closed only after the engine stops using it. |
