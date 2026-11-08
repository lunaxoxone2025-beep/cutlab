#include "player.hpp"

#include <algorithm>
#include <cstring>

#include "json.hpp"
#include "miniaudio.h"

namespace cutlab::media {

namespace {
constexpr int kOutRate = 48000;
constexpr int kOutChannels = 2;
using Clock = std::chrono::steady_clock;

Ticks since(Clock::time_point t0, Clock::time_point t1) {
  const auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count();
  return mul_div(ns, kTicksPerSecond, 1'000'000'000, Rounding::Down);
}
}  // namespace

// miniaudio device wrapper (kept out of the header).
struct Player::AudioOut {
  ma_context context{};
  bool context_ok = false;
  ma_device device{};
  bool device_ok = false;
  bool started = false;
  Ticks latency = 0;

  static void callback(ma_device* dev, void* out, const void* /*in*/, ma_uint32 frames) {
    static_cast<Player*>(dev->pUserData)->audio_callback(static_cast<float*>(out), frames);
  }

  bool open(Player* owner, bool null_backend) {
    ma_backend null_only[] = {ma_backend_null};
    if (ma_context_init(null_backend ? null_only : nullptr, null_backend ? 1 : 0, nullptr, &context) != MA_SUCCESS) return false;
    context_ok = true;
    ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format = ma_format_f32;
    cfg.playback.channels = kOutChannels;
    cfg.sampleRate = kOutRate;
    cfg.dataCallback = &AudioOut::callback;
    cfg.pUserData = owner;
    cfg.performanceProfile = ma_performance_profile_low_latency;
    if (ma_device_init(&context, &cfg, &device) != MA_SUCCESS) return false;
    device_ok = true;
    const ma_uint32 buffered = device.playback.internalPeriodSizeInFrames * std::max<ma_uint32>(1, device.playback.internalPeriods);
    const ma_uint32 rate = device.playback.internalSampleRate ? device.playback.internalSampleRate : kOutRate;
    latency = mul_div(buffered, kTicksPerSecond, rate, Rounding::Nearest);
    return true;
  }

  void start() {
    if (device_ok && !started && ma_device_start(&device) == MA_SUCCESS) started = true;
  }
  void stop() {
    if (device_ok && started) {
      ma_device_stop(&device);
      started = false;
    }
  }
  ~AudioOut() {
    if (device_ok) ma_device_uninit(&device);
    if (context_ok) ma_context_uninit(&context);
  }
};

Player::Player(const Source& src, PlayerOptions opts) : opts_(opts) {
  // Each decoder opens its own demuxer, so audio and video read independently.
  try {
    DecodeOptions vo;
    vo.max_width = opts.max_width;
    vo.max_height = opts.max_height;
    vo.prefer_hardware = opts.prefer_hardware;
    video_ = std::make_unique<VideoDecoder>(src, vo);
    duration_ = video_->duration();
  } catch (const MediaError&) {
    video_.reset();  // audio-only file
  }
  try {
    audio_ = std::make_unique<AudioDecoder>(src, kOutRate, kOutChannels);
    duration_ = std::max(duration_, audio_->duration());
  } catch (const MediaError&) {
    audio_.reset();  // silent video
  }
  if (!video_ && !audio_) throw MediaError("no playable stream in " + src.describe());

  ring_capacity_ = static_cast<size_t>(kOutRate / 2) * kOutChannels;  // 0.5 s
  if (audio_) {
    out_ = std::make_unique<AudioOut>();
    audio_device_ok_ = out_->open(this, opts.null_audio_device);
    if (!audio_device_ok_) out_.reset();  // no device: fall back to the steady clock
  }
  video_seek_pending_ = video_ != nullptr;
  video_seek_target_ = 0;
  audio_seek_pending_ = audio_ != nullptr;
  if (video_) video_thread_ = std::thread(&Player::video_loop, this);
  if (audio_) audio_thread_ = std::thread(&Player::audio_loop, this);
}

Player::~Player() {
  {
    std::lock_guard<std::mutex> lock(mu_);
    quit_ = true;
    playing_ = false;
  }
  cv_.notify_all();
  if (out_) out_->stop();
  if (video_thread_.joinable()) video_thread_.join();
  if (audio_thread_.joinable()) audio_thread_.join();
  out_.reset();
}

bool Player::playing() const {
  std::lock_guard<std::mutex> lock(mu_);
  return playing_;
}

Ticks Player::position_locked() const {
  if (!playing_) return paused_at_;
  Ticks t;
  if (audio_ && audio_device_ok_) {
    t = base_ + mul_div(consumed_, kTicksPerSecond, kOutRate, Rounding::Down);
    // Interpolate between device callbacks (at most 30 ms) for smooth video.
    if (consumed_ > 0) t += std::min<Ticks>(since(last_callback_, Clock::now()), kTicksPerSecond * 3 / 100);
    // What the device has taken is still buffered before it is heard.
    t = std::max(base_, t - out_->latency);
  } else {
    t = base_ + since(started_, Clock::now());
  }
  return duration_ > 0 ? std::min(t, duration_) : t;
}

Ticks Player::position() const {
  std::lock_guard<std::mutex> lock(mu_);
  return position_locked();
}

void Player::play() {
  bool start_device = false;
  {
    std::lock_guard<std::mutex> lock(mu_);
    if (playing_) return;
    if (duration_ > 0 && paused_at_ >= duration_) {
      // At the end: play again from the start.
      paused_at_ = 0;
      ++generation_;
      video_seek_pending_ = video_ != nullptr;
      video_seek_target_ = 0;
      video_seek_accurate_ = true;
      audio_seek_pending_ = audio_ != nullptr;
      audio_seek_target_ = 0;
      queue_.clear();
      ring_.clear();
    }
    base_ = paused_at_;
    consumed_ = 0;
    started_ = Clock::now();
    last_callback_ = started_;
    playing_ = true;
    start_device = out_ != nullptr;
  }
  cv_.notify_all();
  if (start_device) out_->start();
}

void Player::pause() {
  {
    std::lock_guard<std::mutex> lock(mu_);
    if (!playing_) return;
    paused_at_ = position_locked();
    if (audio_ && audio_device_ok_) {
      // Resume exactly where the ring buffer continues (no interpolation).
      paused_at_ = base_ + mul_div(consumed_, kTicksPerSecond, kOutRate, Rounding::Down);
    }
    playing_ = false;
  }
  if (out_) out_->stop();
  cv_.notify_all();
}

void Player::seek(Ticks t, bool accurate) {
  {
    std::lock_guard<std::mutex> lock(mu_);
    t = std::max<Ticks>(0, duration_ > 0 ? std::min(t, duration_) : t);
    ++generation_;
    video_seek_pending_ = video_ != nullptr;
    video_seek_target_ = t;
    video_seek_accurate_ = accurate;
    audio_seek_pending_ = audio_ != nullptr;
    audio_seek_target_ = t;
    queue_.clear();
    ring_.clear();
    video_eof_ = false;
    audio_eof_ = false;
    base_ = t;
    paused_at_ = t;
    consumed_ = 0;
    started_ = Clock::now();
    last_callback_ = started_;
  }
  cv_.notify_all();
}

void Player::video_loop() {
  std::unique_lock<std::mutex> lock(mu_);
  while (!quit_) {
    cv_.wait(lock, [&] {
      return quit_ || video_seek_pending_ || (!video_eof_ && queue_.size() < static_cast<size_t>(opts_.video_queue_frames));
    });
    if (quit_) break;
    bool do_seek = false;
    Ticks target = 0;
    bool accurate = true;
    if (video_seek_pending_) {
      do_seek = true;
      target = video_seek_target_;
      accurate = video_seek_accurate_;
      video_seek_pending_ = false;
    }
    const uint64_t gen = generation_;
    lock.unlock();
    VideoFrame f;
    bool ok = false;
    try {
      if (do_seek) video_->seek(target, accurate);
      ok = video_->next(f);
    } catch (const MediaError&) {
      ok = false;  // treat a broken stream like its end
    }
    lock.lock();
    if (gen != generation_) continue;  // a newer seek arrived meanwhile
    if (ok) {
      queue_.push_back(std::move(f));
      ++frames_decoded_;
    } else {
      video_eof_ = true;
    }
    if (video_->still_image()) video_eof_ = true;  // one frame is all there is
  }
}

void Player::audio_loop() {
  std::vector<float> chunk(1024 * kOutChannels);
  std::unique_lock<std::mutex> lock(mu_);
  while (!quit_) {
    cv_.wait(lock, [&] { return quit_ || audio_seek_pending_ || (!audio_eof_ && ring_.size() + chunk.size() <= ring_capacity_); });
    if (quit_) break;
    bool do_seek = audio_seek_pending_;
    const Ticks target = audio_seek_target_;
    audio_seek_pending_ = false;
    const uint64_t gen = generation_;
    lock.unlock();
    size_t n = 0;
    try {
      if (do_seek) audio_->seek(target);
      n = audio_->read(chunk.data(), chunk.size() / kOutChannels);
    } catch (const MediaError&) {
      n = 0;
    }
    lock.lock();
    if (gen != generation_) continue;
    ring_.insert(ring_.end(), chunk.begin(), chunk.begin() + static_cast<std::ptrdiff_t>(n * kOutChannels));
    if (n < chunk.size() / kOutChannels) audio_eof_ = true;
  }
}

void Player::audio_callback(float* out, uint32_t frames) {
  const size_t want = static_cast<size_t>(frames) * kOutChannels;
  std::unique_lock<std::mutex> lock(mu_, std::try_to_lock);
  if (!lock.owns_lock() || !playing_) {
    std::memset(out, 0, want * sizeof(float));
    return;
  }
  const size_t have = std::min(want, ring_.size());
  std::copy(ring_.begin(), ring_.begin() + static_cast<std::ptrdiff_t>(have), out);
  ring_.erase(ring_.begin(), ring_.begin() + static_cast<std::ptrdiff_t>(have));
  if (have < want) {
    std::memset(out + have, 0, (want - have) * sizeof(float));
    if (!audio_eof_) ++underruns_;
  }
  // The clock only advances by what was really played, so video waits for
  // audio when decoding falls behind.
  consumed_ += static_cast<int64_t>(have / kOutChannels);
  last_callback_ = Clock::now();
  if (audio_eof_ && ring_.empty()) {
    // Keep time moving after the audio ends (video may be longer).
    consumed_ += static_cast<int64_t>((want - have) / kOutChannels);
  }
  lock.unlock();
  cv_.notify_all();
}

void Player::update_end_locked() {
  if (playing_ && duration_ > 0 && position_locked() >= duration_) {
    paused_at_ = duration_;
    playing_ = false;
  }
}

bool Player::frame(uint64_t* serial, uint8_t* dst, size_t capacity, int* w, int* h, Ticks* pts) {
  bool stop_device = false;
  std::unique_lock<std::mutex> lock(mu_);
  const bool was_playing = playing_;
  update_end_locked();
  stop_device = was_playing && !playing_;
  const Ticks now = position_locked();
  bool changed = false;
  int consumed = 0;
  while (!queue_.empty()) {
    const bool need_first = !has_current_ || current_generation_ != generation_;
    if (!need_first && queue_.front().pts > now) break;
    current_ = std::move(queue_.front());
    queue_.pop_front();
    has_current_ = true;
    current_generation_ = generation_;
    changed = true;
    ++consumed;
    if (need_first && !playing_) break;  // paused after a seek: show exactly the seek frame
  }
  if (consumed > 1) frames_dropped_ += consumed - 1;
  if (changed) ++current_serial_;
  const bool deliver = has_current_ && serial && *serial != current_serial_;
  bool copied = false;
  if (deliver) {
    const size_t need = current_.rgba.size();
    if (w) *w = current_.width;
    if (h) *h = current_.height;
    if (pts) *pts = current_.pts;
    if (dst && capacity >= need) {
      std::memcpy(dst, current_.rgba.data(), need);
      *serial = current_serial_;
      copied = true;
    }
  }
  lock.unlock();
  if (changed) cv_.notify_all();
  if (stop_device && out_) out_->stop();
  return copied;
}

std::string Player::stats_json() const {
  std::lock_guard<std::mutex> lock(mu_);
  JsonWriter j;
  j.begin_object();
  j.key("positionTicks").value(position_locked());
  j.key("durationTicks").value(duration_);
  j.key("playing").value(playing_);
  j.key("hasVideo").value(video_ != nullptr);
  j.key("hasAudio").value(audio_ != nullptr);
  j.key("audioDevice").value(audio_device_ok_);
  j.key("audioLatencyTicks").value(out_ ? out_->latency : Ticks{0});
  j.key("decoder").value(video_ ? video_->decoder_name() : std::string());
  j.key("hardware").value(video_ ? video_->hardware() : false);
  j.key("framesDecoded").value(frames_decoded_);
  j.key("framesDropped").value(frames_dropped_);
  j.key("queuedFrames").value(static_cast<int64_t>(queue_.size()));
  j.key("audioBufferedTicks").value(mul_div(static_cast<int64_t>(ring_.size() / kOutChannels), kTicksPerSecond, kOutRate, Rounding::Down));
  j.key("audioUnderruns").value(underruns_);
  j.end_object();
  return j.str();
}

}  // namespace cutlab::media
