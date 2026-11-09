// Real-time playback of an edited timeline (internal header).
//
//   plan (text from the app) ──► TimelinePlayer
//      video thread: picture segments → VideoDecoder per clip → frame queue
//      mixer thread: Mixer (all audible clips, gains, fades) → ring → device
//      prepare thread: opens the next clips' decoders ahead of time
//   clock = audio samples the device has played (video follows audio)
#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "audio_decoder.hpp"
#include "audio_output.hpp"
#include "effects.hpp"
#include "video_decoder.hpp"

namespace cutlab::media {

enum class TlKind { video, image, audio };
class Compositor;

/// A transition into a clip from the clip before it on the same track (the
/// one ending exactly where this one starts). It runs over
/// [start - left, start + right): overlapping kinds show the previous clip
/// continuing past its end and this clip from before its start (media
/// handles, checked by the app); dips fade the previous clip to a colour
/// over `left` and this clip in over `right`.
struct TlTransitionIn {
  bool on = false;
  TransitionKind kind = TransitionKind::dissolve;
  Direction dir = Direction::left;
  Ticks left = 0;
  Ticks right = 0;
};

struct TlClip {
  std::string id;
  std::string uri;  // what the engine opens: a path or "fd:N"
  Ticks start = 0;
  Ticks duration = 0;
  Ticks src_in = 0;  // source time shown at `start`
  float volume = 1.0f;
  Ticks fade_in = 0;
  Ticks fade_out = 0;
  bool audio = false;  // the clip's sound is part of the mix
  bool still = false;  // a photo (one picture for the whole clip)
  std::vector<TlEffect> effects;  // enabled effects, applied in order
  Ticks vfade_in = 0;    // picture from black over the first vfade_in
  Ticks vfade_out = 0;   // picture to black over the last vfade_out
  TlTransitionIn tin;    // transition from the previous clip
  // Set by TlPlan::parse from the transitions: how far the clip's picture
  // and sound reach before its start / after its end (overlap transitions).
  Ticks lead = 0;
  Ticks tail = 0;
  Ticks xfade_out_left = 0;  // audio cross-fade of the transition out
  Ticks end() const { return start + duration; }
  /// True when this clip needs the compositor (effects or video fades).
  bool styled() const { return !effects.empty() || vfade_in > 0 || vfade_out > 0; }
};

struct TlTrack {
  std::string id;
  TlKind kind = TlKind::video;
  bool muted = false;
  bool solo = false;
  bool hidden = false;
  float volume = 1.0f;
  std::vector<TlClip> clips;  // sorted by start, not overlapping
};

/// A picture drawn over the video (export only; titles rendered by the app):
/// straight-alpha RGBA, w × h pixels, at (x, y) of the output frame.
struct TlOverlay {
  Ticks start = 0;
  Ticks duration = 0;
  int x = 0;
  int y = 0;
  int w = 0;
  int h = 0;
  std::string path;  // raw RGBA bytes (w * h * 4)
  Ticks end() const { return start + duration; }
};

/// What to play. Tracks are listed bottom to top: later picture tracks cover
/// earlier ones (as in the editor).
struct TlPlan {
  std::vector<TlTrack> tracks;
  float master = 1.0f;
  bool hardware = false;  // hardware video decoding allowed
  Ticks duration = 0;     // end of the last clip (or overlay, or the "duration" line)
  std::vector<TlOverlay> overlays;  // export only; playback ignores them
  int canvas_w = 0;  // project picture size (0 = not given: the preview uses the clip sizes)
  int canvas_h = 0;
  Rational fps{30, 1};       // project frame rate (preview of effects/transitions)
  int preview_height = 0;    // preview quality: canvas height limit (0 = player default)
  /// Any effect, video fade or transition: the picture goes through the
  /// compositor (preview and export alike).
  bool composite = false;

  /// Parses the text the app sends (see docs/PLAYBACK.md). Throws
  /// std::invalid_argument with the line number on malformed input.
  static TlPlan parse(const std::string& text);

  bool any_solo() const;
  /// Heard: not muted, and soloed when any track is soloed.
  bool audible(const TlTrack& t) const;
};

/// [start, end) of the timeline and the clip whose picture shows there
/// (null = black: no clip, or only hidden tracks).
struct TlSegment {
  Ticks start = 0;
  Ticks end = 0;
  const TlClip* clip = nullptr;
};

/// The whole timeline split where the visible picture changes.
std::vector<TlSegment> picture_segments(const TlPlan& plan);

/// Identifies the picture part of a plan: equal strings = same pictures
/// (mix-only changes such as volume keep video playback undisturbed).
std::string picture_signature(const TlPlan& plan);

constexpr int kMixRate = AudioOutput::kRate;
constexpr int kMixChannels = AudioOutput::kChannels;
/// Ticks per sample at 48 kHz (exact: 705,600,000 / 48,000).
constexpr Ticks kTicksPerSample = kTicksPerSecond / kMixRate;

inline int64_t ticks_to_samples(Ticks t) { return t >= 0 ? t / kTicksPerSample : -((-t + kTicksPerSample - 1) / kTicksPerSample); }
inline Ticks samples_to_ticks(int64_t s) { return s * kTicksPerSample; }

/// Renders the audio of a plan: every audible clip, decoded and resampled
/// to 48 kHz stereo, times clip volume × fade × track volume, summed, times
/// the master volume, limited to [-1, 1]. Positions are timeline samples.
///
/// One decoder per audible clip, opened when the clip is needed (or before,
/// through prepare()) and closed when playback is past it.
class Mixer {
 public:
  Mixer() = default;
  Mixer(const Mixer&) = delete;
  Mixer& operator=(const Mixer&) = delete;

  /// out: frames × 2 floats. track_peaks (size = tracks, may be null): peak
  /// per track before the master volume; *master_peak: peak of the mix.
  void render(const TlPlan& plan, int64_t pos, size_t frames, float* out, float* track_peaks, float* master_peak);

  /// Opens and positions decoders for clips audible in [pos, pos + ahead)
  /// (called from another thread so clip changes do not wait for files).
  void prepare(const TlPlan& plan, int64_t pos, int64_t ahead);

  int decoders_open() const;
  int64_t clipped_samples() const { return clipped_.load(); }
  std::string last_error() const;

 private:
  struct Source {
    std::unique_ptr<AudioDecoder> dec;
    int64_t next = -1;  // clip-relative sample read() returns next
    bool failed = false;
  };
  static std::string key(const TlClip& c) { return c.id + '\n' + c.uri; }
  Source* source_for(const TlClip& c, int64_t clip_sample);
  static std::unique_ptr<Source> open(const TlClip& c, int64_t clip_sample, std::string* error);
  void forget_far(const TlPlan& plan, int64_t pos);

  mutable std::mutex mu_;
  std::map<std::string, std::unique_ptr<Source>> sources_;  // used by render()
  std::map<std::string, std::unique_ptr<Source>> ready_;    // opened by prepare()
  std::vector<float> tmp_;
  std::atomic<int64_t> clipped_{0};
  std::string error_;
  int renders_ = 0;
};

struct TimelineOptions {
  int max_width = 1280;
  int max_height = 720;
  bool null_audio_device = false;
  int video_queue_frames = 8;
  size_t video_queue_bytes = 48u << 20;
};

class TimelinePlayer {
 public:
  explicit TimelinePlayer(TimelineOptions opts);
  ~TimelinePlayer();
  TimelinePlayer(const TimelinePlayer&) = delete;
  TimelinePlayer& operator=(const TimelinePlayer&) = delete;

  /// Replaces what is played. Playback continues; the picture is re-sought
  /// only when the picture part changed (volume/mute/solo/fades apply to
  /// the audio within ~0.2 s).
  void set_plan(std::shared_ptr<const TlPlan> plan);
  std::shared_ptr<const TlPlan> plan() const;

  void play();
  void pause();
  bool playing() const;
  /// accurate=false: nearest earlier keyframe (fast scrubbing).
  void seek(Ticks t, bool accurate);
  Ticks position() const;
  Ticks duration() const;

  /// Copies the picture due now into dst when it changed since *serial.
  /// *w = *h = 0 means black (gap). Returns false if nothing changed or dst
  /// is too small (required: w * h * 4).
  bool frame(uint64_t* serial, uint8_t* dst, size_t capacity, int* w, int* h, Ticks* pts);

  /// Recent peak levels (0..1+) per track and the master as the last value,
  /// for what is being heard now. Zeros while paused.
  size_t levels(float* out, size_t capacity) const;

  std::string stats_json() const;

 private:
  struct QFrame {
    Ticks pts = 0;
    VideoFrame frame;  // rgba empty = black
  };
  struct ActiveVideo {
    std::string key;
    std::unique_ptr<VideoDecoder> dec;
    Ticks last_pts = -1;  // timeline time of the last frame given out
  };
  struct PreparedVideo {
    std::string key;
    Ticks seg_start = -1;
    std::unique_ptr<VideoDecoder> dec;
    VideoFrame first;
    bool has_first = false;
  };
  struct LevelBlock {
    int64_t pos = 0;
    std::vector<float> peaks;  // tracks..., master
  };

  void video_loop();
  void mix_loop();
  void prepare_loop();
  static void audio_trampoline(void* self, float* out, uint32_t frames) { static_cast<TimelinePlayer*>(self)->audio_callback(out, frames); }
  void audio_callback(float* out, uint32_t frames);

  // Video thread helpers (own the video decoders).
  std::vector<QFrame> video_seek(const std::vector<TlSegment>& segs, const TlPlan& plan, Ticks t, bool accurate);
  std::vector<QFrame> video_next(const std::vector<TlSegment>& segs, const TlPlan& plan);
  std::vector<QFrame> enter_segment(const std::vector<TlSegment>& segs, const TlPlan& plan, size_t i);
  ActiveVideo& video_for(const TlClip& c, const TlPlan& plan);
  // Composed timelines (effects, video fades, transitions): pictures drawn
  // by the compositor on the project frame-rate grid, at preview size.
  std::vector<QFrame> comp_seek(const TlPlan& plan, Ticks t);
  std::vector<QFrame> comp_next(const TlPlan& plan);
  QFrame comp_frame(Ticks t, bool black);
  void comp_ensure(const TlPlan& plan);
  std::unique_ptr<VideoDecoder> open_video(const TlClip& c, const TlPlan& plan);
  static std::string video_key(const TlClip& c) { return c.id + '\n' + c.uri; }
  static Ticks to_timeline(const TlClip& c, Ticks src_pts) { return c.start + (src_pts - c.src_in); }

  Ticks position_locked() const;
  void update_end_locked();
  void reposition_locked(Ticks t, bool accurate);
  size_t queue_bytes_locked() const;

  TimelineOptions opts_;
  std::unique_ptr<AudioOutput> out_;
  bool audio_device_ok_ = false;

  mutable std::mutex mu_;
  std::condition_variable cv_;
  bool quit_ = false;
  std::shared_ptr<const TlPlan> plan_;
  std::shared_ptr<const std::vector<TlSegment>> segments_;
  std::string picture_sig_;
  uint64_t generation_ = 0;

  // Clock (as in Player).
  bool playing_ = false;
  Ticks base_ = 0;
  int64_t consumed_ = 0;
  std::chrono::steady_clock::time_point started_;
  std::chrono::steady_clock::time_point last_callback_;
  Ticks paused_at_ = 0;

  // Video (queue shared; decoders owned by the video thread).
  bool vseek_pending_ = true;
  Ticks vseek_target_ = 0;
  bool vseek_accurate_ = true;
  bool video_eof_ = false;
  std::deque<QFrame> queue_;
  QFrame current_;  // its pixels are in current_px_
  std::shared_ptr<const std::vector<uint8_t>> current_px_;
  bool has_current_ = false;
  uint64_t current_generation_ = 0;
  uint64_t current_serial_ = 0;
  size_t cur_seg_ = 0;  // video thread
  std::vector<ActiveVideo> active_;  // video thread
  std::unique_ptr<Compositor> comp_;  // video thread
  int64_t comp_n_ = 0;                // next grid frame
  Ticks comp_last_push_ = 0;
  PreparedVideo prepared_;           // guarded by mu_
  std::string video_error_;
  std::string video_decoder_;
  bool video_hw_ = false;

  // Audio.
  Mixer mixer_;
  bool aseek_pending_ = true;
  int64_t mix_pos_ = 0;  // next timeline sample the mixer renders
  std::deque<float> ring_;
  size_t ring_capacity_ = 0;
  std::deque<LevelBlock> level_hist_;

  // Statistics.
  int64_t frames_shown_ = 0;
  int64_t frames_dropped_ = 0;
  int64_t frames_decoded_ = 0;
  int64_t underruns_ = 0;
  double late_sum_ms_ = 0;
  double late_max_ms_ = 0;
  int64_t late_count_ = 0;
  int64_t mix_ns_ = 0;
  int64_t mixed_samples_ = 0;
  int64_t transitions_ = 0;
  int64_t prepared_hits_ = 0;
  std::chrono::steady_clock::time_point play_wall_start_;
  int64_t play_samples_at_start_ = 0;

  std::thread video_thread_;
  std::thread mix_thread_;
  std::thread prepare_thread_;
};

}  // namespace cutlab::media
