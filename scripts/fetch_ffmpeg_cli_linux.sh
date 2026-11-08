#!/usr/bin/env bash
# Downloads a current FFmpeg 8.1 command-line build for Linux x64 (BtbN,
# LGPL) into <dir>/bin, for checking exported files independently.
#
#   scripts/fetch_ffmpeg_cli_linux.sh <dir>        (needs gh with GH_TOKEN)
set -euo pipefail
DIR="$(mkdir -p "${1:?dir}" && cd "$1" && pwd)"
name=$(gh release view latest -R BtbN/FFmpeg-Builds --json assets --jq '.assets[].name' | grep -m1 -E 'n8\.1-latest-linux64-lgpl-[0-9.]+\.tar\.xz$')
gh release download latest -R BtbN/FFmpeg-Builds -p "$name" -D "$DIR" --clobber
tar -xf "$DIR/$name" -C "$DIR" --strip-components=1
rm -f "$DIR/$name"
"$DIR/bin/ffmpeg" -version | head -1
