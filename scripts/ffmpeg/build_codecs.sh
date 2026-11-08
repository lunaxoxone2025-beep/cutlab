#!/usr/bin/env bash
# Builds the encoder libraries the CUTLAB export engine links into FFmpeg,
# as static libraries with pkg-config files, into <prefix>.
#
#   scripts/ffmpeg/build_codecs.sh <target> <prefix>
#
# target: linux-x64 | android-arm64 | android-x86_64
#
# All of them are BSD-licensed, so the engine stays LGPL-compatible (no
# GPL x264/x265):
#   opus      Opus audio (WebM)                       BSD-3
#   libvpx    VP9 video (WebM)                        BSD-3
#   openh264  H.264 video, software                   BSD-2 (Cisco)
#   kvazaar   H.265/HEVC video, software              BSD-3
#   SVT-AV1   AV1 video, software (linux-x64 only)    BSD-3-Clause-Clear
#
# Patents: H.264, HEVC and AAC are patent-encumbered formats. CUTLAB is a
# private, personal-use build; see docs/EXPORT.md ("Licensing").
#
# Environment: ANDROID_NDK_HOME (android), JOBS, WORK.
set -euo pipefail

TARGET="${1:?target}"
PREFIX="$(mkdir -p "${2:?prefix}" && cd "$2" && pwd)"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"
WORK="${WORK:-$(pwd)/build/codecs-work}/$TARGET"
mkdir -p "$WORK"

OPUS_TAG=v1.5.2
VPX_TAG=v1.15.2
OPENH264_TAG=v2.6.0
KVAZAAR_TAG=v2.3.1
SVTAV1_TAG=v3.1.2

fetch() {  # repo tag dir
  if [ ! -d "$WORK/$3/.git" ]; then
    rm -rf "${WORK:?}/$3"
    git -c advice.detachedHead=false clone --depth 1 --branch "$2" "https://github.com/$1.git" "$WORK/$3"
  fi
}

CMAKE_TC=()
case "$TARGET" in
  linux-x64)
    CC=${CC:-cc}; CXX=${CXX:-c++}; AR=ar; RANLIB=ranlib; STRIP=strip
    HOST_FLAGS=()
    ;;
  android-arm64 | android-x86_64)
    : "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME}"
    API=24
    TC="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
    if [ "$TARGET" = android-arm64 ]; then ABI=arm64-v8a; TRIPLE=aarch64-linux-android; else ABI=x86_64; TRIPLE=x86_64-linux-android; fi
    CC="$TC/bin/$TRIPLE$API-clang"; CXX="$TC/bin/$TRIPLE$API-clang++"
    AR="$TC/bin/llvm-ar"; RANLIB="$TC/bin/llvm-ranlib"; STRIP="$TC/bin/llvm-strip"
    # Bionic has pthreads in libc; FindThreads' test program does not always
    # link with the NDK toolchain under CMake 4, so tell it directly.
    CMAKE_TC=(-DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" -DANDROID_ABI=$ABI
      -DANDROID_PLATFORM=android-$API -DANDROID_STL=c++_static -DCMAKE_HAVE_LIBC_PTHREAD=ON -DCMAKE_THREAD_LIBS_INIT=)
    ;;
  *)
    echo "unknown target $TARGET" >&2
    exit 2
    ;;
esac
export CC CXX AR RANLIB
CFLAGS_COMMON="-O2 -fPIC"

cmake_build() {  # srcdir builddir args...
  local src=$1 bld=$2
  shift 2
  # The toolchain file picks the compilers (CC/CXX are for the Makefile builds).
  env -u CC -u CXX -u AR -u RANLIB cmake -S "$src" -B "$bld" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF "${CMAKE_TC[@]}" "$@"
  cmake --build "$bld" -j "$JOBS"
  cmake --install "$bld"
}

# --- opus
fetch xiph/opus "$OPUS_TAG" opus
cmake_build "$WORK/opus" "$WORK/opus-build" -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_INSTALL_PKG_CONFIG_MODULE=ON

# --- libvpx (VP9 only)
fetch webmproject/libvpx "$VPX_TAG" libvpx
case "$TARGET" in
  linux-x64) VPX_TARGET=x86_64-linux-gcc ;;
  android-arm64) VPX_TARGET=arm64-android-gcc ;;
  android-x86_64) VPX_TARGET=x86_64-android-gcc ;;
esac
rm -rf "$WORK/vpx-build" && mkdir -p "$WORK/vpx-build"
(
  cd "$WORK/vpx-build"
  export LD="$CC" AS="${AS:-}"
  [ "$TARGET" = android-arm64 ] && export AS="$CC"
  CROSS="" "$WORK/libvpx/configure" --prefix="$PREFIX" --target=$VPX_TARGET \
    --disable-examples --disable-tools --disable-docs --disable-unit-tests --disable-vp8 --enable-vp9 \
    --enable-vp9-highbitdepth --enable-pic --disable-shared --enable-static --enable-runtime-cpu-detect \
    --disable-webm-io --disable-libyuv --as=$([ "$TARGET" = android-arm64 ] && echo auto || echo nasm) \
    --extra-cflags="$CFLAGS_COMMON"
  make -j"$JOBS"
  make install
)

# --- openh264 (Makefile build)
fetch cisco/openh264 "$OPENH264_TAG" openh264
(
  cd "$WORK/openh264"
  make clean >/dev/null 2>&1 || true
  case "$TARGET" in
    linux-x64) ARGS=(ARCH=x86_64) ;;
    android-arm64) ARGS=(OS=android NDKROOT="$ANDROID_NDK_HOME" TARGET=android-$API ARCH=arm64 NDKLEVEL=$API) ;;
    android-x86_64) ARGS=(OS=android NDKROOT="$ANDROID_NDK_HOME" TARGET=android-$API ARCH=x86_64 NDKLEVEL=$API) ;;
  esac
  make -j"$JOBS" "${ARGS[@]}" PREFIX="$PREFIX" CFLAGS_OPT="-O2" libraries
  make "${ARGS[@]}" PREFIX="$PREFIX" install-static
)
# The static library is C++: it needs the C++ runtime when linked from C.
if [ "$TARGET" = linux-x64 ]; then CXXRT="-lstdc++ -lm -lpthread"; else CXXRT="-lc++_static -lc++abi -lm"; fi
PC="$PREFIX/lib/pkgconfig/openh264.pc"
if grep -q '^Libs.private:' "$PC"; then sed -i "s/^Libs.private:.*/& $CXXRT/" "$PC"; else echo "Libs.private: $CXXRT" >> "$PC"; fi

# --- kvazaar (CMake)
fetch ultravideo/kvazaar "$KVAZAAR_TAG" kvazaar
# A GNU-assembler-only flag kvazaar adds on x86; clang (NDK) rejects it.
grep -rl 'muse-unaligned-vector-move' "$WORK/kvazaar" --include=CMakeLists.txt --include='*.cmake' | xargs -r sed -i 's/-Wa,-muse-unaligned-vector-move//g'
# kvazaar destroys its (never created) rate-distortion log mutexes every time
# an encoder closes; Bionic aborts on that ("pthread_mutex_destroy called on
# a destroyed mutex"), so the second HEVC export crashed on Android. Only
# release what was opened.
RDO="$WORK/kvazaar/src/rdo.c"
if ! grep -q 'cutlab: opened only' "$RDO"; then
  sed -i 's|    if (curr_mtx != NULL) {|    if (curr != NULL \&\& curr_mtx != NULL) { /* cutlab: opened only */|' "$RDO"
  sed -i 's|      fclose(curr);|      fclose(curr);\n      fastrd_learning_outfile[i] = NULL;|' "$RDO"
  grep -q 'cutlab: opened only' "$RDO" || { echo "kvazaar patch did not apply" >&2; exit 1; }
fi
cmake_build "$WORK/kvazaar" "$WORK/kvazaar-build" -DBUILD_TESTS=OFF -DBUILD_KVAZAAR_BINARY=OFF -DUSE_CRYPTO=OFF

# --- SVT-AV1 (software AV1; desktop only: far too slow on phones)
if [ "$TARGET" = linux-x64 ]; then
  fetch AOMediaCodec/SVT-AV1 "$SVTAV1_TAG" svtav1
  cmake_build "$WORK/svtav1" "$WORK/svtav1-build" -DBUILD_APPS=OFF -DBUILD_DEC=OFF -DBUILD_TESTING=OFF -DENABLE_NASM=ON
fi

# Static linking needs the libraries' own dependencies in their .pc files
# (FFmpeg's configure links a test program with them).
for pc in kvazaar vpx SvtAv1Enc opus; do
  f="$PREFIX/lib/pkgconfig/$pc.pc"
  [ -f "$f" ] || continue
  if grep -q '^Libs.private:' "$f"; then
    grep -q '^Libs.private:.*-lm' "$f" || sed -i 's/^Libs.private:.*/& -lm/' "$f"
  else
    echo 'Libs.private: -lm' >> "$f"
  fi
done

echo "codec libraries for $TARGET installed in $PREFIX:"
ls "$PREFIX/lib"/*.a
