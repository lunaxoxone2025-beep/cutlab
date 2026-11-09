#!/usr/bin/env bash
# Generates the media files used by the engine tests (needs the ffmpeg CLI).
#
#   scripts/make_test_media.sh <output-dir> [ffmpeg-binary]
#
# Every video encodes its frame number in the luma of each frame
# (gray level = frame index mod 256), so tests can check that a seek
# returned exactly the right frame.
set -euo pipefail
OUT="${1:?output dir}"
FF="${2:-ffmpeg}"
mkdir -p "$OUT"
q() { "$FF" -hide_banner -loglevel error -y "$@"; }

gray() { # rate frames
  echo "nullsrc=s=320x180:r=$1,format=gray,geq=lum='mod(N\,256)',format=yuv420p"
}

# 10 s, 60 fps, H.264 + AAC with a 1 kHz tone between 2.0 s and 2.1 s.
q -f lavfi -i "$(gray 60)" -f lavfi -i "aevalsrc='if(between(t\,2\,2.1)\,0.8*sin(2*PI*1000*t)\,0)':s=48000:c=stereo" \
  -t 10 -c:v libx264 -preset veryfast -crf 1 -g 60 -bf 2 -c:a aac -b:a 128k -movflags +faststart "$OUT/gray60.mp4"

# 5 s, 120 fps, H.264 in MKV, no audio.
q -f lavfi -i "$(gray 120)" -t 5 -c:v libx264 -preset veryfast -crf 1 -g 120 "$OUT/gray120.mkv"

# Variable frame rate: 60 fps for the first second, then 30 fps (frames 60.. are 1/30 s apart).
q -f lavfi -i "$(gray 60)" -t 3 -vf "setpts='if(lt(N\,60)\,N/60\,1+(N-60)/30)/TB'" -fps_mode passthrough \
  -c:v libx264 -preset veryfast -crf 1 -g 30 "$OUT/vfr.mkv"

# Phone-style portrait clip: stored 320x180 with a 90 degree rotation flag.
q -f lavfi -i "$(gray 30)" -t 2 -c:v libx264 -preset veryfast -crf 10 "$OUT/rot_src.mp4"
q -display_rotation 90 -i "$OUT/rot_src.mp4" -c copy "$OUT/rotated.mp4"
rm -f "$OUT/rot_src.mp4"

# HEVC 10-bit (common for phone/console captures).
q -f lavfi -i "$(gray 30)" -t 2 -pix_fmt yuv420p10le -c:v libx265 -preset ultrafast -x265-params log-level=error -crf 10 "$OUT/hevc10.mp4" || \
  echo "libx265 not available: skipping hevc10.mp4"

# Audio-only and image files.
q -f lavfi -i "sine=frequency=440:duration=3:sample_rate=44100" -c:a libmp3lame -b:a 128k "$OUT/tone.mp3" || \
  q -f lavfi -i "sine=frequency=440:duration=3:sample_rate=44100" "$OUT/tone.wav"
q -f lavfi -i "color=c=red:s=64x48" -frames:v 1 "$OUT/red.png"

# Effects and transitions: a picture with a gray ramp (left half) and two
# flat colours (right half), and two flat-colour clips with steady tones of
# different pitch (audio continuity across cross-fades). Long enough for
# transition handles.
q -f lavfi -i "nullsrc=s=320x180:r=30,format=gbrp,geq=r='if(lt(X\,160)\,X*255/159\,if(lt(Y\,90)\,200\,40))':g='if(lt(X\,160)\,X*255/159\,if(lt(Y\,90)\,80\,90))':b='if(lt(X\,160)\,X*255/159\,if(lt(Y\,90)\,40\,200))',format=yuv420p" \
  -t 4 -c:v libx264 -preset veryfast -crf 1 -g 30 "$OUT/colors.mp4"
flat() { # r g b tone-hz name
  q -f lavfi -i "color=c=0x$(printf '%02x%02x%02x' "$1" "$2" "$3"):s=320x180:r=30,format=yuv420p" \
    -f lavfi -i "aevalsrc='0.4*sin(2*PI*$4*t)|0.4*sin(2*PI*$4*t)':s=48000:d=6" \
    -t 6 -c:v libx264 -preset veryfast -crf 1 -g 30 -c:a pcm_s16le "$OUT/$5"
}
flat 220 60 60 500 flat_red.mkv
flat 50 70 220 700 flat_blue.mkv

# Mixer tests: tones of exactly known amplitude (0.5).
q -f lavfi -i "aevalsrc='0.5*sin(2*PI*1000*t)|0.5*sin(2*PI*1000*t)':s=48000:d=6" -c:a pcm_s16le "$OUT/tone1k.wav"
q -f lavfi -i "aevalsrc='0.5*sin(2*PI*440*t)':s=44100:d=6" -c:a aac -b:a 192k "$OUT/tone440.m4a"

# Two-hour recording (tiny frames so it is quick to make) for long-file seeks.
q -f lavfi -i "$(gray 30 | sed 's/320x180/96x54/')" -f lavfi -i "anullsrc=r=16000:cl=mono" -t 7200 \
  -c:v libx264 -preset ultrafast -crf 20 -g 300 -c:a aac -b:a 24k -movflags +faststart "$OUT/long2h.mp4"

ls -la "$OUT"
