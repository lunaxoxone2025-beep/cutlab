# Android preview crash — investigation and fixes (CUTLAB 0.4.1 → 0.4.2)

## Root cause (confirmed in 0.4.2 from the owner's crash report)

The 0.4.20 build's crash report from the owner's phone pinned it down. Phone: Xiaomi 23053RN02Y (Redmi, MediaTek MT6769, Android 15, 8 GB RAM). Process memory was only ~225 MB, so it was **not** a memory problem.

The engine's crash handler recorded the backtrace and Android's own record added "Pointer tag … was truncated". The `symbolize` workflow resolved the offsets with the unstripped library of that exact build:

```
abort ← free ← av_freep ← av_channel_layout_copy        (FFmpeg)
      ← AudioDecoder::decode_more()  audio_decoder.cpp:93
      ← AudioDecoder::read() ← Player::audio_loop()      (player audio thread)
```

`decode_more()` declared `AVChannelLayout in_layout;` **without initialising it**. Then it called `av_channel_layout_copy(&in_layout, …)`, which first frees whatever the destination holds. When the leftover stack bytes happened to look like a "custom" layout, FFmpeg called `free()` on a stack address, and Android's allocator aborted the app.

Whether it crashes depends on what an earlier call left on that thread's stack. That depends on the device, compiler and C library, which is why it never happened on Linux, Windows or the emulators. On this phone it happened about 0.1 s after starting the preview of an HEVC 720p phone video: the moment the audio started decoding.

**Fix:**
- Both layouts are zero-initialised.
- The engine is now compiled with `-ftrivial-auto-var-init=zero`, so any similar mistake becomes harmless.
- CI runs valgrind on a build without that option, so new mistakes are still reported. Valgrind flags this exact bug in the old code (60 errors) and reports 0 errors after the fix.

The 0.4.1 changes below (memory limits, separate hardware-decoder test, exception safety) remain. Each one fixes a real way for the app to die.

## Stability review (0.4.2)

| Area | Check | Result |
|---|---|---|
| Native memory leaks | valgrind `--leak-check=full`: full engine test suite (156 checks, incl. 2-hour file) and the preview stress test | 0 bytes in use at exit, 0 errors (1.2 million allocations in the stress test, all freed) |
| Uninitialised memory / invalid frees | valgrind memcheck, also in CI on every change | 0 errors after the fix |
| Data races | ThreadSanitizer stress run | only known false positives inside FFmpeg's own threading; none in CUTLAB's player state |
| Decoder threads | player threads are joined on close; per-size thread limits; single-frame decodes share a budget | stress test: players opened/closed, half of them after 5 ms, with monitor frames and thumbnails running |
| Hardware → software fallback | failure to open or to decode switches to software; crashes are contained in the `:hwprobe` process | emulator API 28 (MediaCodec unavailable → software) and API 34 (MediaCodec used; 4K 10-bit falls back) |
| Several decoders at once | preview + 2 monitor decoders + thumbnails | stress test, emulator full-editor test |
| Repeated open/close | 25 quick cycles on the emulators; hundreds in the stress test | no crash, no leak |
| Corrupt/unsupported files | truncated, random bytes, AV1 without a decoder | clear error, app keeps running |
| Android lifecycle | no Android surface is used (frames are Flutter images). When the app goes to the background the preview pauses, which also stops the audio device | widget test |

## Diagnostics after an unexpected end

- **Native crash:** the report is written by the crash handler at the moment of the crash, before the process ends.
- **Java crash:** the report is written by the Java handler before the process ends.
- **Killed without a signal handler** (e.g. Android ending the app for memory): the engine also appends every activity line straight to `engine-activity.log`. The next start keeps it as `engine-activity-previous.log`, and it appears in the report as "Engine activity of the previous run". Android 11+ adds its own record of the kill.
- **Privacy:** engine messages never contain file names or paths, only "the video" or "the mp4 file". The report filter also removes paths, `content://`/`file://` URIs and media file names (shown as `<file>`) from anything else. Kept: codec, resolution, frame rate, decoder names, memory, device model. No video content is ever included.

## Earlier investigation (0.4.1)

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

## Results on Android emulators (fixed code, CI run of 9e9cbf3)

All 21 integration tests and all native tests passed on **API 28** (Android 9) and **API 34** (Android 14). Both emulators are x86_64 with 2 CPUs and 4 GB of RAM.

| | API 28 | API 34 |
|---|---|---|
| Hardware check (separate process) | MediaCodec does not start on this image: every kind of video → software | H.264 1080p30/60, portrait, VFR and HEVC 1080p60 pass and use `h264_mediacodec`/`hevc_mediacodec`. HEVC 10-bit 4K and the 720p long file fail to start → software |
| Playback, every file, hardware on/off | frames delivered, no errors | frames delivered, no errors |
| Open/close ×25, broken/AV1 files | OK; clear error messages | OK; clear error messages |
| Full editor: 4 clips on the timeline + preview (process memory, whole app) | timeline 348 MB; previewing 4K HEVC 10-bit 622 MB; peak 638 MB | timeline 398 MB; previewing 4K HEVC 10-bit 612 MB; peak 661 MB |

The "tombstones" in these runs come from `cutlab_crash_report_tests`, which crashes on purpose. They also show that Android's own crash reporter still runs after CUTLAB's handler.

## What is not proven

- *(0.4.1, superseded above)* The exact cause was not confirmed then: no crash log from the phone was available.
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
