# CUTLAB video export (Phase 6)

## What is exported

Export renders the **whole project from the original files**. It does not
record the preview monitor. Each output frame is built at the export size:

- **Picture:** the top-most visible clip at that time (the same rule as
  playback), decoded in its own pixel format. It is scaled with a bicubic
  filter to fit the frame (letterbox/pillarbox, never stretched) and turned
  upright when the phone recorded it rotated. Photos with transparency sit
  on black.
- **Titles:** drawn by the app at the export resolution with the same font,
  size and position as the monitor (sizes relative to the picture height),
  then blended into the frame by the engine.
- **Gaps** are black and silent. The file is exactly as long as the project
  (titles included), rounded up to whole frames.
- **Sound:** the playback mixer, run offline. It includes every audible clip
  on every track, clip and track volume, mute and solo, fades, and the
  master volume. Output is 48 kHz stereo. Each frame's sound is mixed for
  exactly that frame, so picture and sound cannot drift: a click at 1.000 s
  in the project is at 1.000 s in the file, also after 2 hours (tested).
- **Frame rate:** constant. Each output frame shows the source frame that is
  on screen at that moment. 30 fps sources in a 60 fps export are repeated,
  60 fps sources in a 30 fps export skip frames evenly, and variable-rate
  phone recordings follow their own timestamps. Frames are never dropped
  to save time.

The file is written as `<name>.part` and renamed when complete. A stopped,
failed or interrupted export leaves no broken file behind.

## Formats and encoders

| Codec | File | Hardware (when it works on the device) | Software |
|---|---|---|---|
| H.264 | MP4, MKV, MOV | Android MediaCodec, NVIDIA NVENC, Intel Quick Sync, AMD AMF, Windows Media Foundation | Windows' own H.264 encoder (Windows), OpenH264 (Android, Linux) |
| H.265 / HEVC | MP4, MKV, MOV | MediaCodec, NVENC, Quick Sync, AMF, Media Foundation | kvazaar |
| VP9 | WebM, MKV | MediaCodec, Quick Sync | libvpx |
| AV1 | MP4, WebM, MKV | MediaCodec (newer phones), NVENC (RTX 40+), Quick Sync (Arc), AMF (RX 7000+), Media Foundation | SVT-AV1 and libaom (PC only; too slow on phones) |

Sound is AAC in MP4/MOV/MKV and Opus in WebM, 128–320 kbit/s.

**How an encoder is chosen.** The app lists the encoders that work. On
Android, the hardware encoders are tested once in a separate process
(`:hwprobe`), so a broken vendor encoder can only end that process, not the
app. Then:

- If hardware encoding is on, the working hardware encoders are tried
  first, then software.
- If an encoder fails when starting or while encoding (no GPU, missing
  driver, missing Windows codec pack), the export restarts from the
  beginning with the next encoder and says so.
- Only if every encoder fails does the export fail, with the message.

### Quality

- **Presets** (Best, High, Standard, Small file) map to a quality value
  (90, 75, 60, 40).
- **Software encoders** use constant quality: libvpx and SVT-AV1 CRF,
  kvazaar QP. Simple scenes get small files and fast action gets more bits.
- **Hardware encoders and OpenH264** get a target bitrate from the same
  quality value. It is High ≈ 12 Mbit/s for 1080p60 H.264, about −35 % for
  HEVC/VP9 and −50 % for AV1, and it doubles every 20 quality points.
- **Advanced mode** adds a fixed bitrate (1–150 Mbit/s), encoder effort
  (fast / balanced / best quality), keyframe interval, audio bitrate and
  encoder threads.
- **Estimated size** is (video bitrate + audio bitrate) × length.
  Constant-quality software encodes can come out smaller, especially
  for static footage.

### Gaming footage

COD Mobile, Minecraft and other gaming recordings get these treatments:

- Frames are never skipped; the frame rate is constant and exact (24, 30,
  60 and 120 fps; 29.97 is kept in the engine).
- Scaling is bicubic. Exporting at the recording's own size does no scaling
  at all.
- Colours are converted from each source's own colour matrix to BT.709
  (tagged in the file).
- OpenH264 never drops frames to hold a bitrate (`allow_skip_frames 0`).
- 60 fps exports keep the 60 fps motion; HEVC/AV1 give the same quality
  in smaller files.
- Long recordings stream from disk. Memory does not grow with the length,
  and 2-hour exports are tested.

## Android and Windows

**Android**

- The export keeps running in the background. A foreground service shows
  the progress in a notification, and a partial wake lock lets it continue
  with the screen off.
- When Android reports the phone as too hot (thermal status "severe" or
  worse), the export pauses and continues by itself once the phone has
  cooled down.
- Low battery and battery saver are shown.
- Fewer encoder threads (advanced mode) make the export cooler and slower.
- The finished video goes to **Movies/CUTLAB** in the gallery (Android 10+).
  On Android 7–9 it stays in the app's own folder
  (`Android/data/…/files/Movies/exports`).
- Memory: one decoded picture per visible clip, one composed frame, and the
  encoder's own buffers.

**Windows**

- The user chooses where to save.
- GPU encoders are tried first (NVENC, Quick Sync, AMF, Media Foundation).
  CPU encoding is the fallback.
- "Show file" opens Explorer at the file.

## Checking the result

After every export the app reads the file back. It checks the size, frame
rate, length, codec and sound track against the settings and lists every
difference; it never claims a check passed when it did not.

Automated checks:

| Test | What |
|---|---|
| `core/tests/test_export.cpp` | The complete timeline (two clips, gap, portrait clip covering on an upper track, photo, sound track with volume and fade, title, letterboxed into 4:3). Every picture is compared with the source frame that should be there (frame-numbered gray videos). The sound is measured at known times, including A/V sync to the sample. Also: mute/solo/master/clip volume; every codec × file format in the build; 480p–4K, 24–120 fps and 29.97 with exact frame counts; pause/resume, stop, stop cycles, close while running (no file left); unreadable and cut-off files (export completes, black and silence, warnings); hardware allowed (falls back); bitrate mode; a 2-hour export with A/V checked at its end. |
| `scripts/verify_exports.py` | Every file from those tests is checked again with ffprobe/ffmpeg, which share no code with CUTLAB: codec, size, frame rate, exact frame count (all frames decoded and counted), audio stream, and a full decode with zero errors. Runs on Linux, Windows and the files exported on the Android emulators. |
| `test/export_test.dart` | Settings (sizes, defaults, formats, bitrate formula, engine text), titles (time spans, drawing, placement), controller (plan, encoder order, progress, pause, heat pause, stop, failure and retry in software, result check), export screen. |
| `integration_test/export_test.dart` | In the real app on the Android emulators and on Windows: every working encoder exports 2 s and is read back; then a project is exported from the editor (export screen, progress, saved file, in-app check), and the file's title pixels and sound are checked. |

## Performance (measured in CI)

`cutlab_export_tests --bench`, 3 s of each real-size recording (2 s for 4K),
encoder effort "balanced", picture + sound. Columns: encoding frames per
second, × real time (1.00 = as fast as the video plays), and the bitrate
written at quality High.

**Linux CI machine (4 CPU cores, software encoders):**

| Source → output | H.264 (OpenH264) | HEVC (kvazaar) | VP9 (libvpx) | AV1 (SVT-AV1 2.3) |
|---|---|---|---|---|
| 1080p60 H.264 → 1080p60 | 132 fps (2.2×), 12.2 Mbit/s | 70 fps (1.2×), 9.4 | 18 fps (0.3×), 18.3 | 61 fps (1.0×), 13.9 |
| 1080p60 HEVC → 1080p60 | 142 fps (2.4×) | 66 fps (1.1×) | 16 fps (0.3×) | 64 fps (1.1×) |
| 1080p30 → 720p30 | 145 fps (4.8×), 3.2 Mbit/s | 120 fps (4.0×) | 28 fps (0.9×) | 92 fps (3.1×) |
| 4K HEVC 10-bit → 4K30 | 30 fps (1.0×), 27.6 Mbit/s | 17 fps (0.6×) | 4 fps (0.1×) | 16 fps (0.5×) |

**Android emulator (x86_64, 2 cores, software encoders; a phone's ARM cores and its hardware encoder will differ):**

| Source → output | H.264 (OpenH264) | HEVC (kvazaar) | VP9 (libvpx) |
|---|---|---|---|
| 1080p60 → 1080p60 | 108–109 fps (1.8×) | 11–12 fps (0.2×) | 50–56 fps (0.8–0.9×) |
| 1080p30 → 720p30 | 97–131 fps (3.3–4.4×) | 23–28 fps (0.8–0.9×) | 62–72 fps (2.1–2.4×) |
| 4K HEVC 10-bit → 4K30 | 23 fps (0.8×) | 3–3.5 fps (0.1×) | 9–11 fps (0.3×) |

On the emulators, a 2-second 720p30 export with Android's own (MediaCodec)
encoders took about 0.5–0.8 s for H.264, VP9 and AV1 and 5–6 s for HEVC.
The emulator's HEVC MediaCodec encoder is a slow software one; a phone has a
hardware one.

**Other measurements:**

- 2-hour recording at 192×108, 24 fps: 172,800 frames in 29–38 s on Linux CI (about 200–250× real time), with the A/V position exact at the end.
- Windows CI, Windows' own H.264 encoder (software): 145 fps at 1080p30, 39 fps at 4K24.
- Exported from the real app's export screen (720p30, 4 s project): 1–2 s on the emulators and about 1 s on Windows.

**Reading these for gaming footage:**

- At 1080p60, software H.264 exports about twice as fast as real time on a PC; SVT-AV1 about real time.
- A 1-hour 1080p60 recording takes roughly 25–30 min with H.264 on the CI machine. It should be quicker on a desktop with a GPU encoder (NVENC/Quick Sync/AMF), but that is not measured in CI.
- kvazaar HEVC is slow on phones without a hardware HEVC encoder. Prefer H.264 there, or a phone whose hardware HEVC encoder passes the test.
- libvpx VP9 is the slowest; use "Fast" effort for long VP9 exports.

## Settings text (app → engine)

`cutlab_export_start(plan, settings)`. The plan is the playback plan
(docs/PLAYBACK.md) plus:

```
duration <ticks>                                   # project length (titles included)
overlay <start> <duration> <x> <y> <w> <h> <path>  # a title: raw straight RGBA, w*h*4 bytes
```

The settings are one `key value` per line:

```
path <file>            container mp4|mov|webm|mkv      video h264|hevc|vp9|av1|mpeg4
encoder <a,b,c>        size <W>x<H>                    fps <num>/<den>
quality <1-100>        bitrate <kbit/s>                speed fast|balanced|quality
hardware 0|1           keyframes <seconds>             audio aac|opus|none
audio_bitrate <kbit/s> threads <n>
```

## Licensing

CUTLAB is a private, personal-use build and is not distributed.

**FFmpeg** is built as LGPL. No `--enable-gpl` or `--enable-nonfree`, and
no x264 or x265. The encoder libraries are all BSD-licensed, built from
source by `scripts/ffmpeg/build_codecs.sh`:

- OpenH264 (BSD-2, Cisco)
- libvpx (BSD-3)
- kvazaar (BSD-3)
- SVT-AV1 (BSD-3-Clause-Clear)
- Opus (BSD-3)

On Windows the BtbN LGPL FFmpeg build provides the same libraries plus
libaom.

**Hardware and system encoders** (MediaCodec, NVENC, Quick Sync, AMF,
Media Foundation) are part of the device or its drivers.

**Patents.** H.264, HEVC and AAC are covered by patent pools:

- OpenH264 is built from source here, not Cisco's binary, so Cisco's
  patent licence for the binary does not apply.
- Hardware/system encoders are licensed through the device or operating
  system.
- VP9, AV1 and Opus are royalty-free.

Any public release would need a licensing review first. That is out of
scope for this personal project.

## Limitations (not done yet)

| Item | Status |
|---|---|
| Resume after the app is closed | An export that is stopped or killed (app closed, phone restarted) starts again from the beginning. Pause/resume works while the app runs. |
| Compositing | Only the top-most picture. No picture-in-picture, transparency, transitions, effects, keyframes or colour work yet (later phases). |
| Clip speed / reverse | Exported at normal speed (as in playback; the editor has no control yet). |
| Background colour | Gaps and borders are always black; the project's background setting is not used yet. |
| HDR | HDR/10-bit sources are converted to 8-bit SDR BT.709 without tone mapping (colours may look flat); output is 8-bit. |
| Titles | Plain centred text, the same as the monitor. |
| Android hardware encoders | Tested on the emulators' MediaCodec encoders (H.264, HEVC, VP9, AV1 on Android 14; H.264 on Android 9). The owner's phone's encoders, speed, heat and battery behaviour are not measured yet. |
| kvazaar HEVC speed | Software HEVC is slow (0.2× real time at 1080p60 on the emulator); hardware HEVC or H.264 is recommended on phones. |
| Windows GPU encoders | The CI machines have no GPU: NVENC/Quick Sync/AMF are tested only in the sense that they fail cleanly and the export falls back. |
| Software AV1 on phones | Not included (minutes per second of video); AV1 on Android needs a hardware encoder. |
| Faststart | MP4/MOV files are rewritten at the end so they start playing at once; for very long exports this "Finishing" step takes a while. |
| Android 7–9 | The video stays in the app's folder instead of the gallery. |
| SVT-AV1 version | SVT-AV1 3.1 sometimes never finished a stream in CI, so the Linux/CI build uses 2.3.0 (30 of 30 short AV1 exports finish; about half the speed of 3.1). The Windows build uses BtbN's SVT-AV1. If any encoder stops responding for 60 s, the export is reported as failed instead of hanging, and closing it never blocks the app for more than 3 s. |
| WebM/Opus and old players | Ubuntu's FFmpeg 6.1 rejects one Opus packet in WebM exports (written by libopus 1.5); FFmpeg 8.1 and CUTLAB read them correctly. Players built on old FFmpeg versions may complain; MP4 with AAC (the default) is not affected. |
| AV1 import (Linux, emulator builds) | These engine builds have no AV1 decoder, so AV1 files cannot be previewed there (exports are checked with ffprobe instead). |
