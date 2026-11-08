// Engine diagnostics (internal header): breadcrumbs of recent engine
// activity, FFmpeg warnings, memory figures and the native crash handler.
#pragma once

#include <cstdint>
#include <string>

namespace cutlab::diag {

/// Records one line ("player open fd:57 hevc 3840x2160 decoder=hevc_mediacodec hw=1").
/// Cheap and thread-safe; the last lines are written into crash reports and
/// returned by recent(). Also goes to logcat on Android.
void note(const char* fmt, ...)
#if defined(__GNUC__) || defined(__clang__)
    __attribute__((format(printf, 1, 2)))
#endif
    ;

/// The most recent notes, oldest first, one per line.
std::string recent();

/// Resident memory of this process in KiB (current, peak); 0 when unknown.
void memory_kib(int64_t* rss, int64_t* peak);

/// Hardware (MediaCodec/D3D11/...) decoders currently open.
void hardware_decoder_opened();
void hardware_decoder_closed();
int hardware_decoders_open();

/// Installs the crash handler writing to <dir>/native-crash.txt and routes
/// FFmpeg warnings into the notes. device_info is copied into every report.
/// Every note is also appended to <dir>/engine-activity.log as it happens
/// (written straight to the file, so it survives the process being killed,
/// e.g. by Android when memory runs out); the previous run's log is kept as
/// engine-activity-previous.log. Safe to call again.
void init(const std::string& dir, const std::string& device_info);

/// Routes FFmpeg warnings/errors into the notes (also done by init()).
void capture_ffmpeg_log();

}  // namespace cutlab::diag
