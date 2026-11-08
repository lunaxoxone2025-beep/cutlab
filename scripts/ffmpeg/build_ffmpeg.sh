#!/usr/bin/env bash
# Builds a minimal, static, LGPL FFmpeg for the CUTLAB media engine.
#
#   scripts/ffmpeg/build_ffmpeg.sh <target> <prefix>
#
# target: linux-x64 | android-arm64 | android-x86_64 (emulator tests)
# prefix: install directory (gets include/ and lib/)
#
# Reading: the demuxers, decoders and parsers for common recordings (MP4/MOV,
# MKV/WebM, MPEG-TS, FLV, AVI, common audio files, images).
# Export (Phase 6): MP4/MOV/WebM/MKV muxers, FFmpeg's AAC encoder, and the
# encoder libraries from build_codecs.sh when CODECS_PREFIX is set (OpenH264,
# libvpx VP9, kvazaar HEVC, SVT-AV1, Opus). Without them only FFmpeg's own
# encoders are available (development builds).
#
# Android additionally enables the MediaCodec hardware decoders and encoders
# (needs the Java VM, which the engine registers in JNI_OnLoad).
#
# Environment: ANDROID_NDK_HOME (android), FFMPEG_SRC (optional existing
# source tree), CODECS_PREFIX (build_codecs.sh output), JOBS.
set -euo pipefail

TARGET="${1:?target}"
PREFIX="$(mkdir -p "${2:?prefix}" && cd "$2" && pwd)"
FFMPEG_TAG="${FFMPEG_TAG:-n8.1.3}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"
WORK="${WORK:-$(pwd)/build/ffmpeg-work}"
SRC="${FFMPEG_SRC:-$WORK/src}"

if [ ! -f "$SRC/configure" ]; then
  mkdir -p "$(dirname "$SRC")"
  git clone --depth 1 --branch "$FFMPEG_TAG" https://github.com/FFmpeg/FFmpeg.git "$SRC"
fi

DEMUXERS=mov,matroska,mpegts,flv,avi,mp3,wav,flac,ogg,aac,ac3,eac3,w64,image2,image_png_pipe,image_jpeg_pipe,image_webp_pipe,image_bmp_pipe,gif,h264,hevc
DECODERS=h264,hevc,vp8,vp9,mpeg4,mpeg2video,mpeg1video,h263,mjpeg,png,webp,bmp,gif,prores,aac,aac_latm,mp3,mp3float,mp2,opus,vorbis,flac,alac,ac3,eac3,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_u8,pcm_alaw,pcm_mulaw
PARSERS=h264,hevc,vp8,vp9,av1,aac,aac_latm,mpegaudio,opus,vorbis,flac,mjpeg,png,webp,ac3,mpeg4video,mpegvideo,gif,bmp
BSFS=h264_mp4toannexb,hevc_mp4toannexb,vp9_superframe_split,vp9_superframe,extract_extradata,av1_frame_split
MUXERS=mp4,mov,webm,matroska
ENCODERS=aac,mpeg4,pcm_s16le

EXT=()
if [ -n "${CODECS_PREFIX:-}" ]; then
  export PKG_CONFIG_PATH="$CODECS_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  EXT+=(--pkg-config-flags=--static "--extra-cflags=-I$CODECS_PREFIX/include" "--extra-ldflags=-L$CODECS_PREFIX/lib")
  have() { pkg-config --exists "$1"; }
  if have opus; then EXT+=(--enable-libopus); ENCODERS+=,libopus; fi
  if have vpx; then EXT+=(--enable-libvpx); ENCODERS+=,libvpx_vp9; fi
  if have openh264; then EXT+=(--enable-libopenh264); ENCODERS+=,libopenh264; fi
  if have kvazaar; then EXT+=(--enable-libkvazaar); ENCODERS+=,libkvazaar; fi
  if have SvtAv1Enc; then EXT+=(--enable-libsvtav1); ENCODERS+=,libsvtav1; fi
  echo "encoder libraries: ${EXT[*]}"
fi

COMMON=(
  --disable-everything --disable-programs --disable-doc --disable-network
  --disable-avdevice --disable-avfilter --disable-debug
  --enable-static --disable-shared --enable-pic
  --enable-avcodec --enable-avformat --enable-avutil --enable-swscale --enable-swresample
  --enable-protocol=file,pipe
  "--enable-demuxer=$DEMUXERS" "--enable-decoder=$DECODERS" "--enable-parser=$PARSERS" "--enable-bsf=$BSFS"
  "--enable-muxer=$MUXERS" "--enable-encoder=$ENCODERS"
  --disable-autodetect --enable-pthreads --enable-zlib
  "--prefix=$PREFIX"
)

case "$TARGET" in
  linux-x64)
    EXTRA=()
    ;;
  android-arm64)
    : "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}"
    API=24
    TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
    EXTRA=(
      --target-os=android --arch=aarch64 --cpu=armv8-a --enable-cross-compile
      "--sysroot=$TOOLCHAIN/sysroot"
      "--cc=$TOOLCHAIN/bin/aarch64-linux-android$API-clang"
      "--cxx=$TOOLCHAIN/bin/aarch64-linux-android$API-clang++"
      "--ar=$TOOLCHAIN/bin/llvm-ar" "--nm=$TOOLCHAIN/bin/llvm-nm"
      "--ranlib=$TOOLCHAIN/bin/llvm-ranlib" "--strip=$TOOLCHAIN/bin/llvm-strip"
      --enable-neon --enable-asm --enable-inline-asm
      --enable-jni --enable-mediacodec
      --enable-decoder=h264_mediacodec,hevc_mediacodec,vp9_mediacodec,av1_mediacodec,mpeg4_mediacodec
      --enable-encoder=h264_mediacodec,hevc_mediacodec,vp9_mediacodec,av1_mediacodec
    )
    ;;
  android-x86_64)
    # Only for the Android emulator tests in CI (x86_64 emulators run with KVM).
    : "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}"
    API=24
    TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
    EXTRA=(
      --target-os=android --arch=x86_64 --enable-cross-compile
      "--sysroot=$TOOLCHAIN/sysroot"
      "--cc=$TOOLCHAIN/bin/x86_64-linux-android$API-clang"
      "--cxx=$TOOLCHAIN/bin/x86_64-linux-android$API-clang++"
      "--ar=$TOOLCHAIN/bin/llvm-ar" "--nm=$TOOLCHAIN/bin/llvm-nm"
      "--ranlib=$TOOLCHAIN/bin/llvm-ranlib" "--strip=$TOOLCHAIN/bin/llvm-strip"
      --enable-asm --x86asmexe=nasm
      --enable-jni --enable-mediacodec
      --enable-decoder=h264_mediacodec,hevc_mediacodec,vp9_mediacodec,av1_mediacodec,mpeg4_mediacodec
      --enable-encoder=h264_mediacodec,hevc_mediacodec,vp9_mediacodec,av1_mediacodec
    )
    ;;
  *)
    echo "unknown target $TARGET" >&2
    exit 2
    ;;
esac

BUILD="$WORK/build-$TARGET"
rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"
"$SRC/configure" "${COMMON[@]}" "${EXTRA[@]}" "${EXT[@]}" || { tail -50 ffbuild/config.log; exit 1; }
make -j"$JOBS"
make install
echo "FFmpeg $FFMPEG_TAG for $TARGET installed in $PREFIX"
