#!/usr/bin/env bash
# Real-size media for the Android preview tests (needs the ffmpeg CLI with
# libx264, libx265 and, optionally, an AV1 encoder).
#
#   scripts/make_android_test_media.sh <output-dir>
#
# Covers what the owner records: 1080p30/60 H.264, 1080p60 HEVC, 4K HEVC
# 10-bit (phone HDR style), a portrait phone clip (stored landscape with a
# 90 degree rotation flag), a 10-minute recording, VFR, audio, an image, and
# broken/unsupported files that must fail without crashing.
set -euo pipefail
OUT="${1:?output dir}"
mkdir -p "$OUT"
q() { ffmpeg -hide_banner -loglevel error -y "$@"; }
AUD="sine=frequency=440:sample_rate=48000"
X265="-x265-params log-level=error"

q -f lavfi -i "testsrc2=s=1920x1080:r=30" -f lavfi -i "$AUD" -t 6 -c:v libx264 -preset ultrafast -b:v 6M -g 30 \
  -c:a aac -b:a 128k -shortest "$OUT/h264_1080p30.mp4"
q -f lavfi -i "testsrc2=s=1920x1080:r=60" -f lavfi -i "$AUD" -t 6 -c:v libx264 -preset ultrafast -profile:v high -b:v 10M \
  -g 120 -bf 3 -c:a aac -shortest "$OUT/h264_1080p60.mp4"
q -f lavfi -i "testsrc2=s=1920x1080:r=60" -f lavfi -i "$AUD" -t 4 -c:v libx265 -preset ultrafast $X265 -b:v 8M -tag:v hvc1 \
  -c:a aac -shortest "$OUT/hevc_1080p60.mp4"
q -f lavfi -i "testsrc2=s=3840x2160:r=30" -f lavfi -i "$AUD" -t 2 -pix_fmt yuv420p10le -c:v libx265 -preset ultrafast $X265 \
  -b:v 20M -tag:v hvc1 -c:a aac -shortest "$OUT/hevc10_4k30.mp4"
q -f lavfi -i "testsrc2=s=1920x1080:r=60" -f lavfi -i "$AUD" -t 4 -c:v libx264 -preset ultrafast -b:v 12M -c:a aac -shortest "$OUT/p.mp4"
q -display_rotation 90 -i "$OUT/p.mp4" -c copy -movflags +faststart "$OUT/phone_portrait_1080p60.mp4"
rm -f "$OUT/p.mp4"
# Ten minutes of 720p30 (mostly static picture, so the file stays small).
q -f lavfi -i "testsrc=s=1280x720:r=30" -f lavfi -i "anullsrc=r=48000:cl=stereo" -t 600 -c:v libx264 -preset ultrafast \
  -crf 35 -g 300 -c:a aac -b:a 32k "$OUT/long_720p30_10min.mp4"
# Variable frame rate (60 then 30 fps).
q -f lavfi -i "testsrc2=s=640x360:r=60" -t 3 -vf "setpts='if(lt(N\,60)\,N/60\,1+(N-60)/30)/TB'" -fps_mode passthrough \
  -c:v libx264 -preset ultrafast "$OUT/vfr.mkv"
q -f lavfi -i "sine=frequency=440:duration=3:sample_rate=44100" -c:a libmp3lame -b:a 128k "$OUT/tone.mp3"
q -f lavfi -i "color=c=red:s=640x480" -frames:v 1 "$OUT/red.png"

# Must fail cleanly: a file cut in half, random bytes, and AV1 (no software
# decoder in this build; the emulator may or may not have a MediaCodec one).
head -c $(( $(stat -c %s "$OUT/h264_1080p30.mp4") / 2 )) "$OUT/h264_1080p30.mp4" > "$OUT/truncated.mp4"
head -c 300000 /dev/urandom > "$OUT/garbage.mp4"
q -f lavfi -i "testsrc2=s=320x180:r=30" -t 1 -c:v libaom-av1 -cpu-used 8 -b:v 200k "$OUT/av1.mp4" 2>/dev/null || \
  q -f lavfi -i "testsrc2=s=320x180:r=30" -t 1 -c:v libsvtav1 "$OUT/av1.mp4" 2>/dev/null || echo "no AV1 encoder: skipping av1.mp4"

ls -la "$OUT"
