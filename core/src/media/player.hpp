// Real-time playback with audio-driven A/V sync (internal header).
#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#include "audio_decoder.hpp"
#include "video_decoder.hpp"

namespace cutlab::media {

struct PlayerOptions {
  int max_width = 1280;
  int max_height = 720;
  bool prefer_hardware = true;
  bool null_audio_device = false;  // tests / headless: audio is consumed but not heard
  int video_queue_frames = 8;      // decoded frames kept ahead of the playhead
};

/// Plays one media file.
///
/// Threads: a video thread decodes into a small bounded queue; an audio
/// thread decodes into a ring buffer of ~0.5 s that the audio device drains.
/// The playhead clock is the number of audio samples the device has consumed
/// (so video follows what is actually heard); without audio it is a steady
/// clock. Memory is bounded by the queue sizes, independent of file length.
///
/// Thread-safe: all public methods may be called from any thread.
class Player {
 public:
  Player(const Source& src, PlayerOptions opts);
  ~Player();
  Player(const Player&) = delete;
  Player& operator=(const Player&) = delete;

  void play();
  void pause();
  bool playing() const;

  /// accurate=false shows the nearest earlier keyframe (fast scrubbing).
  void seek(Ticks t, bool accurate);

  Ticks position() const;
  Ticks duration() const { return duration_; }
  bool has_audio() const { return audio_ != nullptr; }
  bool has_video() const { return video_ != nullptr; }

  /// Copies the frame that belongs on screen now into dst if it is newer
  /// than *serial (then updates *serial). Returns false if nothing changed or
  /// dst is too small (required size in *w * *h * 4).
  bool frame(uint64_t* serial, uint8_t* dst, size_t capacity, int* w, int* h, Ticks* pts);

  std::string stats_json() const;

 private:
  struct AudioOut;
  friend struct AudioOut;

  void video_loop();
  void audio_loop();
  Ticks position_locked() const;
  void update_end_locked();
  void audio_callback(float* out, uint32_t frames);

  PlayerOptions opts_;
  Ticks duration_ = 0;
  std::unique_ptr<VideoDecoder> video_;
  std::unique_ptr<AudioDecoder> audio_;
  std::unique_ptr<AudioOut> out_;
  bool audio_device_ok_ = false;

  mutable std::mutex mu_;
  std::condition_variable cv_;
  bool quit_ = false;
  bool playing_ = false;
  uint64_t generation_ = 0;  // bumped on every seek; stale work is discarded

  // Clock.
  Ticks base_ = 0;                        // media time at the last seek/play
  int64_t consumed_ = 0;                  // audio frames played since base_
  std::chrono::steady_clock::time_point started_;  // for the steady clock
  std::chrono::steady_clock::time_point last_callback_;
  Ticks paused_at_ = 0;

  // Video.
  bool video_seek_pending_ = false;
  Ticks video_seek_target_ = 0;
  bool video_seek_accurate_ = true;
  bool video_eof_ = false;
  std::deque<VideoFrame> queue_;
  VideoFrame current_;
  bool has_current_ = false;
  uint64_t current_generation_ = 0;
  uint64_t current_serial_ = 0;
  int64_t frames_decoded_ = 0;
  int64_t frames_dropped_ = 0;

  // Audio.
  bool audio_seek_pending_ = false;
  Ticks audio_seek_target_ = 0;
  bool audio_eof_ = false;
  std::deque<float> ring_;
  size_t ring_capacity_ = 0;
  int64_t underruns_ = 0;

  std::thread video_thread_;
  std::thread audio_thread_;
};

}  // namespace cutlab::media
