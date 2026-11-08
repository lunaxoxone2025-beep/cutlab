#!/usr/bin/env bash
# Runs the CUTLAB Android tests on a booted emulator/device (see
# .github/workflows/android-tests.yml).
#
#   run_emulator_tests.sh <native-dir> <media-dir> <app-dir> <logs-dir>
#
# native-dir: libcutlab_core.so + test executables built for the device ABI
# media-dir:  test-media/ (engine tests) and android-media/ (real-size files)
set -uo pipefail
NATIVE="$(cd "$1" && pwd)"
MEDIA="$(cd "$2" && pwd)"
APP="$(cd "$3" && pwd)"
mkdir -p "$4"
LOGS="$(cd "$4" && pwd)"
status=0

adb root >/dev/null 2>&1 && sleep 3   # for tombstones; not available on every image
adb wait-for-device
adb shell getprop ro.build.fingerprint | tee "$LOGS/device.txt"
adb shell getprop ro.product.cpu.abi | tee -a "$LOGS/device.txt"
adb shell cat /proc/meminfo | head -3 | tee -a "$LOGS/device.txt"
adb logcat -c || true
adb logcat -v threadtime > "$LOGS/logcat.txt" 2>&1 &
LOGCAT=$!

# --- native engine tests (plain executables; no Java VM, so no MediaCodec)
D=/data/local/tmp/cutlab
adb shell rm -rf $D
adb shell mkdir -p $D/media $D/real
adb push "$NATIVE/." $D/ >/dev/null
adb push "$MEDIA/test-media/." $D/media/ >/dev/null
adb push "$MEDIA/android-media/." $D/real/ >/dev/null
adb shell chmod 755 $D/cutlab_core_tests $D/cutlab_media_tests $D/cutlab_stress_preview $D/cutlab_crash_report_tests \
  $D/cutlab_timeline_tests $D/cutlab_bench_timeline $D/cutlab_export_tests
native() {
  local name="$1"; shift
  echo "NATIVE-TEST $name: start" | tee -a "$LOGS/native.txt"
  adb shell "cd $D && LD_LIBRARY_PATH=$D $*" >> "$LOGS/native.txt" 2>&1
  local rc=$?
  echo "NATIVE-TEST $name: exit $rc" | tee -a "$LOGS/native.txt"
  [ $rc -eq 0 ] || status=1
}
native core ./cutlab_core_tests
native media CUTLAB_TEST_MEDIA=$D/media ./cutlab_media_tests
native timeline CUTLAB_TEST_MEDIA=$D/media ./cutlab_timeline_tests
native bench ./cutlab_bench_timeline $D/media $D/real
adb shell mkdir -p $D/out $D/bench-out
native export CUTLAB_TEST_MEDIA=$D/media CUTLAB_TEST_OUT=$D/out ./cutlab_export_tests
native export-bench CUTLAB_TEST_MEDIA=$D/media CUTLAB_TEST_OUT=$D/bench-out ./cutlab_export_tests --bench $D/real
adb pull $D/out "$LOGS/exports" >/dev/null 2>&1 || true
adb shell rm -rf $D/bench-out
native crash-report ./cutlab_crash_report_tests $D/crash-report-test
# That test crashes on purpose: drop its tombstones so real ones stand out.
adb shell 'rm -f /data/tombstones/*' >/dev/null 2>&1 || true
native stress ./cutlab_stress_preview 4 real/h264_1080p30.mp4 real/h264_1080p60.mp4 real/hevc_1080p60.mp4 real/hevc10_4k30.mp4 \
  real/phone_portrait_1080p60.mp4 real/long_720p30_10min.mp4 real/vfr.mkv real/tone.mp3 real/red.png
tail -40 "$LOGS/native.txt"

# --- Flutter integration test inside the real app
DEVICE=$(adb devices | awk 'NR==2 {print $1}')
( cd "$APP" && flutter test integration_test/preview_pipeline_test.dart -d "$DEVICE" --reporter expanded ) 2>&1 | tee "$LOGS/flutter.txt"
[ "${PIPESTATUS[0]}" -eq 0 ] || status=1
( cd "$APP" && flutter test integration_test/timeline_playback_test.dart -d "$DEVICE" --reporter expanded ) 2>&1 | tee "$LOGS/flutter-playback.txt"
[ "${PIPESTATUS[0]}" -eq 0 ] || status=1
( cd "$APP" && flutter test integration_test/export_test.dart -d "$DEVICE" --reporter expanded ) 2>&1 | tee "$LOGS/flutter-export.txt"
[ "${PIPESTATUS[0]}" -eq 0 ] || status=1

sleep 2
kill $LOGCAT 2>/dev/null || true
adb pull /data/tombstones "$LOGS/tombstones" >/dev/null 2>&1 || true
ls "$LOGS/tombstones" 2>/dev/null && echo "TOMBSTONES FOUND (native crash)"
echo "android tests status: $status"
exit $status
