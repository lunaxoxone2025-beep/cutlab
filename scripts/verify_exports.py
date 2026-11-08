#!/usr/bin/env python3
"""Independent check of the files written by cutlab_export_tests.

    verify_exports.py <export-dir> [ffprobe] [ffmpeg]

Reads <export-dir>/exports.txt (file|width|height|fps|frames|video|audio,
written by the tests) and checks every file with the FFmpeg command-line
tools, which share no code path with the CUTLAB engine's own reader:
  - codec, size and frame rate of the video stream,
  - the exact number of frames (every frame decoded and counted),
  - the audio stream (codec, 48 kHz, stereo) when one is expected,
  - a full decode of every stream without a single error.
Prints a Markdown table (also appended to $GITHUB_STEP_SUMMARY) and exits 1
on any mismatch.
"""
import json
import os
import subprocess
import sys
from fractions import Fraction

args = [a for a in sys.argv[1:] if not a.startswith("--")]
# --informational: report only (e.g. how an older FFmpeg copes), never fail.
informational = "--informational" in sys.argv
out_dir = args[0]
ffprobe = args[1] if len(args) > 1 else "ffprobe"
ffmpeg = args[2] if len(args) > 2 else "ffmpeg"

rows = []
failures = 0
seen = set()
with open(os.path.join(out_dir, "exports.txt"), encoding="utf-8") as manifest:
    entries = [l.strip().split("|") for l in manifest if l.strip()]

for name, w, h, fps, frames, vcodec, acodec in entries:
    if name in seen:
        continue
    seen.add(name)
    path = os.path.join(out_dir, name)
    problems = []
    if not os.path.exists(path):
        rows.append((name, "missing", "", "", "", "", "FAIL: file missing"))
        failures += 1
        continue
    info = json.loads(subprocess.run(
        [ffprobe, "-v", "error", "-count_frames", "-show_entries",
         "stream=codec_type,codec_name,width,height,r_frame_rate,nb_read_frames,sample_rate,channels:format=duration,size",
         "-of", "json", path], capture_output=True, text=True, check=True).stdout)
    streams = info.get("streams", [])
    video = next((s for s in streams if s["codec_type"] == "video"), None)
    audio = next((s for s in streams if s["codec_type"] == "audio"), None)
    if not video:
        problems.append("no video stream")
    else:
        if video["codec_name"] != vcodec:
            problems.append(f"video codec {video['codec_name']} != {vcodec}")
        if (video["width"], video["height"]) != (int(w), int(h)):
            problems.append(f"size {video['width']}x{video['height']} != {w}x{h}")
        if Fraction(video["r_frame_rate"]) != Fraction(fps):
            problems.append(f"frame rate {video['r_frame_rate']} != {fps}")
        if int(video.get("nb_read_frames", -1)) != int(frames):
            problems.append(f"{video.get('nb_read_frames')} frames != {frames}")
    if acodec:
        if not audio:
            problems.append("no audio stream")
        elif audio["codec_name"] != acodec or int(audio["sample_rate"]) != 48000 or int(audio["channels"]) != 2:
            problems.append(f"audio {audio['codec_name']} {audio['sample_rate']} Hz {audio['channels']} ch")
    elif audio:
        problems.append("unexpected audio stream")
    decode = subprocess.run([ffmpeg, "-v", "error", "-i", path, "-map", "0", "-f", "null", "-"], capture_output=True, text=True)
    if decode.returncode != 0 or decode.stderr.strip():
        problems.append("decode errors: " + decode.stderr.strip()[:300])
        # Details for the log: the audio packets (size, time) at both ends.
        pk = subprocess.run([ffprobe, "-v", "error", "-select_streams", "a", "-show_entries", "packet=pts_time,duration_time,size,flags",
                             "-of", "csv=p=0", path], capture_output=True, text=True).stdout.strip().splitlines()
        print(f"{name}: {len(pk)} audio packets; first {pk[:3]}; last {pk[-3:]}")
        print(f"{name}: decoder said: {decode.stderr.strip()[:1500]}")
    duration = float(info.get("format", {}).get("duration", 0))
    size = int(info.get("format", {}).get("size", 0))
    rows.append((name, f"{video['codec_name'] if video else '-'} {w}x{h}", fps,
                 video.get("nb_read_frames", "?") if video else "-", f"{duration:.3f} s",
                 audio["codec_name"] if audio else "-", "ok" if not problems else "FAIL: " + "; ".join(problems)))
    failures += bool(problems)

table = ["| file | video | fps | frames (counted) | duration | audio | result |", "|---|---|---|---|---|---|---|"]
table += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]
text = "\n".join(table) + f"\n\n{len(rows)} files checked with ffprobe/ffmpeg, {failures} failed.\n"
print(text)
summary = os.environ.get("GITHUB_STEP_SUMMARY")
if summary:
    with open(summary, "a", encoding="utf-8") as f:
        f.write(("### Older FFmpeg (informational)" if informational else "### Exported files, checked independently") + "\n\n" + text)
sys.exit(1 if failures and not informational else 0)
