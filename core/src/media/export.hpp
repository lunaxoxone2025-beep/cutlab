// Rendering a timeline to a video file (internal header).
//
//   plan (same text as playback, plus title overlays) + settings
//     ──► worker thread: for every output frame
//           picture: top-most visible clip at that time, decoded in its own
//                    pixel format, scaled to fit (letterbox), rotated,
//                    titles blended                         ──► video encoder
//           sound:   Mixer (every audible clip, gains, fades) ──► audio encoder
//         ──► muxer (MP4 / MOV / WebM / MKV) ──► <path>.part, renamed at the end
//
// Everything the timeline holds is rendered from the source files at the
// export resolution; nothing is taken from the preview.
#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "timeline.hpp"

namespace cutlab::media {

struct ExportSettings {
  std::string path;                 // final file; written as path + ".part" and renamed when complete
  std::string container = "mp4";    // mp4 | mov | webm | mkv
  std::string video_codec = "h264"; // h264 | hevc | vp9 | av1 | mpeg4
  std::string encoder;              // "" = best available; or FFmpeg encoder names, comma-separated, in order
  int width = 1920;
  int height = 1080;
  Rational fps{30, 1};
  int quality = 75;                 // 1..100, used when video_kbps == 0
  int video_kbps = 0;               // > 0: target bitrate instead of constant quality
  std::string speed = "balanced";   // fast | balanced | quality (encoder effort)
  bool hardware = true;             // hardware encoders allowed
  double keyframe_seconds = 2.0;
  std::string audio_codec = "aac";  // aac | opus | none
  int audio_kbps = 192;
  int threads = 0;                  // encoder threads; 0 = automatic

  /// "key value" lines (see docs/EXPORT.md). Throws std::invalid_argument.
  static ExportSettings parse(const std::string& text);
};

/// One encoder that can be used for a codec.
struct EncoderInfo {
  std::string codec;    // h264 | hevc | vp9 | av1 | mpeg4 | aac | opus
  std::string name;     // FFmpeg encoder name
  bool hardware = false;
  bool usable = true;   // false: compiled in but failed the test (probe=true)
  std::string note;     // why it is not usable
};

/// Encoders compiled into this build, best first per codec. probe=true opens
/// every hardware encoder and encodes a few frames to see that it works.
std::vector<EncoderInfo> available_encoders(bool probe);
std::string encoders_json(const std::vector<EncoderInfo>& list);

/// Target video bitrate (bit/s) for a quality (1..100) — the same formula
/// the app uses for its file size estimate (docs/EXPORT.md).
int64_t quality_bitrate(const std::string& codec, int quality, int width, int height, Rational fps);

class Exporter {
 public:
  enum class State { preparing, rendering, finishing, done, failed, cancelled };

  /// Starts rendering in a background thread.
  Exporter(std::shared_ptr<const TlPlan> plan, ExportSettings settings);
  ~Exporter();  // cancels and waits
  Exporter(const Exporter&) = delete;
  Exporter& operator=(const Exporter&) = delete;

  void pause(bool paused);
  void cancel();
  State state() const;
  bool finished() const;
  std::string status_json() const;
  /// Blocks until finished (tests).
  void wait();

 private:
  struct Overlay;
  struct Run;
  void work();
  void run_once(const EncoderInfo& enc, Run& run);
  void set_state(State s);
  bool wait_if_paused();  // false: cancelled

  std::shared_ptr<const TlPlan> plan_;
  ExportSettings settings_;

  mutable std::mutex mu_;
  std::condition_variable cv_;
  bool paused_ = false;
  std::atomic<bool> cancel_{false};
  State state_ = State::preparing;
  std::string error_;
  std::vector<std::string> warnings_;
  std::string encoder_name_;
  bool encoder_hw_ = false;
  std::string audio_encoder_;
  int64_t frames_total_ = 0;
  int64_t frames_done_ = 0;
  int64_t bytes_ = 0;
  int64_t decode_errors_ = 0;
  int restarts_ = 0;
  std::chrono::steady_clock::time_point started_;
  std::chrono::steady_clock::time_point finished_at_;
  int64_t paused_ns_ = 0;
  std::chrono::steady_clock::time_point paused_since_;
  // Recent speed (frames per second over the last seconds).
  std::chrono::steady_clock::time_point speed_mark_;
  int64_t speed_mark_frames_ = 0;
  double recent_fps_ = 0;

  std::thread worker_;
};

const char* export_state_name(Exporter::State s);

}  // namespace cutlab::media
