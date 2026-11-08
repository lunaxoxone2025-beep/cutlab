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
| Android hardware encoders | Tested on the emulators' encoders only. The owner's phone's encoders, speed, heat and battery behaviour are not measured yet. |
| Windows GPU encoders | The CI machines have no GPU: NVENC/Quick Sync/AMF are tested only in the sense that they fail cleanly and the export falls back. |
| Software AV1 on phones | Not included (minutes per second of video); AV1 on Android needs a hardware encoder. |
| Faststart | MP4/MOV files are rewritten at the end so they start playing at once; for very long exports this "Finishing" step takes a while. |
| Android 7–9 | The video stays in the app's folder instead of the gallery. |
| WebM/Opus and old players | Ubuntu's FFmpeg 6.1 rejects one Opus packet in WebM exports (written by libopus 1.5); FFmpeg 8.1 and CUTLAB read them correctly. Players built on old FFmpeg versions may complain; MP4 with AAC (the default) is not affected. |
| AV1 import (Linux, emulator builds) | These engine builds have no AV1 decoder, so AV1 files cannot be previewed there (exports are checked with ffprobe instead). |
