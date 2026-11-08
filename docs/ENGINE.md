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
 file ──►   │ video thread: VideoDecoder ──► queue (8 frames, RGBA, preview size)
 (path/fd)  │ audio thread: AudioDecoder ──► ring (0.5 s, float 48 kHz stereo) ──► miniaudio device
            │ clock = samples the device consumed − device latency            │
            └──── frame(serial) → UI picks the frame whose pts ≤ clock ───────┘
```

- **Time** is integer ticks (705,600,000/s) everywhere; container timestamps are converted exactly with 128-bit arithmetic. Media time 0 is the container start, for audio and video alike, so their relative offset is preserved.
- **Accurate seek**: seek to the previous keyframe, decode forward, return the last frame whose pts ≤ t (only that frame is converted to RGBA). One time-base unit of slack absorbs millisecond-rounded timestamps (MKV). If the demuxer lands after the target (imprecise index) it backs off and retries.
- **Fast seek** (scrubbing): keyframe only. While dragging the UI sends fast seeks, the final position is accurate. The video thread always works on the latest request; stale work is discarded via a generation counter.
- **Audio** is resampled to 48 kHz float. After a seek the first sample is exactly at t (silence is inserted or samples dropped). Gaps/overlaps > 40 ms in the source are corrected, so long recordings with timestamp hiccups stay in sync.
- **A/V sync**: the clock advances only by samples actually played (minus the device buffer latency), interpolated between callbacks. If decoding falls behind, the audio underruns and the clock — and so the video — waits. Video-only files use a steady clock.
- **Memory** is bounded by design: 8 preview frames (≈ 3.7 MB each at 1280×720) + 0.5 s of audio + FFmpeg's own buffers, regardless of file length. No file is read whole.
- **Colour**: BT.601/709/2020 matrices and full/limited range from the stream tags (untagged ≥ 720p is treated as BT.709). 10-bit sources are converted to 8-bit RGBA for preview.
- **Rotation**: phone videos with a rotation flag are turned upright (clockwise degrees, FFmpeg's convention).
- **Hardware decoding**: Windows tries D3D11VA then DXVA2; Linux VAAPI when FFmpeg has it (our minimal Linux build does not); Android uses FFmpeg's MediaCodec decoders (`h264_mediacodec`, `hevc_mediacodec`, `vp9_mediacodec`, `av1_mediacodec`), enabled by `JNI_OnLoad` when `MainActivity` loads the library. Any failure — opening or mid-stream — falls back to software decoding automatically. Thumbnails always use software (keyframes only, faster than starting a hardware session).

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

1. **Not tested on real devices yet.** Hardware decoding (MediaCodec, D3D11VA) compiles and has an automatic software fallback, but CI machines have no video hardware: it has only been exercised through the fallback path.
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
