# CUTLAB media engine (Phase 3)

The engine is the C++ library `cutlab_core` (`core/`), built with **FFmpeg 8.1** (LGPL) and **miniaudio 0.11.21**. Flutter talks to it only through the C ABI in `core/include/cutlab/cutlab_core.h` via `dart:ffi` (`apps/cutlab/lib/src/engine/`).

## What it does

| Function | C ABI | Notes |
|---|---|---|
| Inspect a file | `cutlab_media_probe` | container, duration, codec, rotation-aware size, frame rate, **VFR detection**, bit depth, audio format, file size — JSON |
| One frame | `cutlab_media_frame` | *accurate*: the frame displayed at time t; *fast*: the keyframe at or before t |
| Thumbnail strip | `cutlab_media_thumbnails` | N keyframes over the whole file; cost depends on N, not on file length |
| Waveform | `cutlab_media_peaks` | min/max per bucket, mono, with progress and cancel |
| Playback | `cutlab_player_*` | video + audio with audio-driven sync, play/pause/seek, frame polling, statistics |

Media is opened by path (PC) or by file descriptor `fd:<n>` (Android `content://` URIs from the Storage Access Framework). Descriptors are duplicated and read with `pread`, so several decoders read one file independently and **nothing is copied**.

## Design

```
            ┌───────────── Player ─────────────┐
 file ──►   │ video thread: VideoDecoder ──► queue (≤ 8 frames and ≤ 48 MB, RGBA, preview size)
 (path/fd)  │ audio thread: AudioDecoder ──► ring (0.5 s, float 48 kHz stereo) ──► miniaudio device
            │ clock = samples the device consumed − device latency            │
            └──── frame(serial) → UI picks the frame whose pts ≤ clock ───────┘
```

- **Time** is integer ticks (705,600,000/s) everywhere; container timestamps are converted exactly with 128-bit arithmetic. Media time 0 is the container start, for audio and video alike, so their relative offset is preserved.
- **Accurate seek**: seek to the previous keyframe, decode forward, return the last frame whose pts ≤ t (only that frame is converted to RGBA). One time-base unit of slack absorbs millisecond-rounded timestamps (MKV). If the demuxer lands after the target (imprecise index) it backs off and retries.
- **Fast seek** (scrubbing): keyframe only. While dragging the UI sends fast seeks, the final position is accurate. The video thread always works on the latest request; stale work is discarded via a generation counter.
- **Audio** is resampled to 48 kHz float. After a seek the first sample is exactly at t (silence is inserted or samples dropped). Gaps/overlaps > 40 ms in the source are corrected, so long recordings with timestamp hiccups stay in sync.
- **A/V sync**: the clock advances only by samples actually played (minus the device buffer latency), interpolated between callbacks. If decoding falls behind, the audio underruns and the clock — and so the video — waits. Video-only files use a steady clock.
- **Memory** is bounded by design and does not depend on the file length (no file is read whole). The preview queue holds at most 8 frames and 48 MB, plus 0.5 s of audio.
- **Decoder threads** depend on the picture size, because each frame thread keeps one decoded picture in flight (a 4K 10-bit picture is ~25 MB): the player uses up to 6 threads, 4 above 1080p and 3 for 4K. Single-frame decoders (timeline monitor, thumbnails, hardware test) use 2 slice threads and share a budget of one 4K picture (or four 1080p) decoding at a time; further requests wait. Editor-like load, 8 CPUs: 4K HEVC 10-bit 1642 → 544 MB, 1080p60 528 → 193 MB (see `docs/ANDROID_PREVIEW_CRASH.md`).
- **Errors never end the app**: every exception on the decoder threads and every player call through the C API is caught. The player stops at a broken stream and reports the error (`error` in the stats), and the viewer shows it.
- **Diagnostics** (`core/src/diag`): a log of the last 64 engine events (decoders opened with codec, size, threads, hardware/software and memory; fallbacks; FFmpeg warnings and errors). It also contains a crash handler for SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT and SIGTRAP (Windows: unhandled exceptions and abort). The handler writes `native-crash.txt` and then passes the signal on to the system's own handler. C API: `cutlab_diag_init`, `cutlab_diag_note`, `cutlab_diag_recent`.
- **Colour**: BT.601/709/2020 matrices and full/limited range from the stream tags (untagged ≥ 720p is treated as BT.709). 10-bit sources are converted to 8-bit RGBA for preview.
- **Rotation**: phone videos with a rotation flag are turned upright (clockwise degrees, FFmpeg's convention).
- **Hardware decoding**: Windows tries D3D11VA then DXVA2; Linux VAAPI when FFmpeg has it (our minimal Linux build does not); Android uses FFmpeg's MediaCodec decoders (`h264_mediacodec`, `hevc_mediacodec`, `vp9_mediacodec`, `av1_mediacodec`), enabled by `JNI_OnLoad` when `MainActivity` loads the library. Any failure — opening or mid-stream — falls back to software decoding automatically, and the reason is reported (`hardwareFallback`). On Android, a vendor decoder can also *crash* the process. That cannot be caught in-process, so each kind of video is first decoded by `cutlab_hw_self_test` in a separate `:hwprobe` process (`HwProbeService`). A crash, hang or failure there means software decoding for that kind of video. Thumbnails and timeline frames always use software (faster than starting a hardware session).

## Measured (Linux CI runner / dev container, software decoding)

Synthetic files from `scripts/make_test_media.sh`; every frame encodes its index in its gray level, so tests verify the exact frame returned.

| Test | Result |
|---|---|
| Accurate seek, 60 fps H.264 (10 frames incl. GOP edges) | exact frame and pts |
| Accurate seek, 120 fps H.264 in MKV | exact frame; pts within MKV's 1 ms rounding |
| VFR (60 → 30 fps) | detected; t = 1.5 s returns frame 75 |
| 2-hour file: accurate seek to 1:59:58.5 | ≈ 20–40 ms |
| 2-hour file: 24 thumbnails | ≈ 16 ms |
| 2-hour file: full waveform (72,000 buckets) | ≈ 1.1 s |
| Audio timing: tone at 2.00–2.10 s | found in buckets 200–209 (10 ms resolution) |
| Player: 1 s of playback | clock 1.02 s, 59 frames shown, max frame lag 4 ms |
| 10-bit HEVC, rotated portrait clip, PNG, MP3 | decoded correctly |
| AddressSanitizer + UBSan + leak check | clean |

Real gameplay files are heavier per frame than these synthetic ones; device timings must be measured on the owner's phone and PC.

## Limitations (known, documented)

1. **Not tested on real devices yet.** On Android emulators (API 34), MediaCodec decoding through FFmpeg is exercised with Google's software codecs; on API 28 it falls back to software. Phone vendor decoders and D3D11VA on a real GPU have not been run.
2. **Preview frames go through the CPU**: decoded RGBA is copied to Dart and uploaded as an image each frame. Fine at 540p/720p; 1080p at 60 fps may drop frames on mid-range phones. GPU texture sharing (Flutter `Texture`) is planned for Phase 9. The player's `framesDropped` statistic shows when this happens.
3. **120 fps playback** displays at the screen refresh rate (usually 60 Hz on phones/PCs): frames are decoded and timed at 120 fps but every other one is skipped on a 60 Hz screen. Frame stepping and frame-accurate seeking work at the full 120 fps.
4. **AV1 software decoding is not included** (it needs libdav1d). AV1 plays only where the Android device has a hardware AV1 decoder, and on Windows if the BtbN FFmpeg build includes dav1d.
5. **Codecs compiled in** (Android/Linux minimal build): H.264, HEVC, VP8, VP9, MPEG-4/2/1, H.263, ProRes, MJPEG, PNG, WebP, BMP, GIF; AAC, MP3, MP2, Opus, Vorbis, FLAC, ALAC, AC-3/E-AC-3, PCM. Containers: MP4/MOV, MKV/WebM, MPEG-TS, FLV, AVI, MP3, WAV, FLAC, OGG, AAC, AC-3. Others (e.g. WMV) fail with a clear "unsupported" message.
6. **Android 7.0 (API 24) or newer, arm64 only.** The APK now contains only the arm64-v8a engine (all mid-range phones since ~2017).
7. **Audio output latency** is estimated from the audio device buffer size; Bluetooth headphones add latency the OS does not report, so video can appear slightly ahead with BT audio.
8. **Linux** is built and packaged but is not a target platform for testing.
9. Proxy files, multi-track compositing and export are not part of this phase (Phases 4–6, 9).

## Building

See `docs/BUILDING.md`. FFmpeg: `scripts/ffmpeg/build_ffmpeg.sh linux-x64|android-arm64 <prefix>` (static, minimal, LGPL); Windows uses `scripts/ffmpeg/fetch_ffmpeg_windows.ps1` (BtbN LGPL shared build). Test media: `scripts/make_test_media.sh <dir>`; run tests with `CUTLAB_TEST_MEDIA=<dir> ctest`.
