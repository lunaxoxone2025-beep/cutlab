// Audio device output (miniaudio), shared by the file player and the
// timeline player (internal header).
#pragma once

#include <cstdint>
#include <memory>

#include "cutlab/time.hpp"

namespace cutlab::media {

/// A 48 kHz stereo float playback device. The callback runs on the audio
/// thread and must fill `frames` frames (silence if nothing to play).
class AudioOutput {
 public:
  using Callback = void (*)(void* user, float* out, uint32_t frames);
  static constexpr int kRate = 48000;
  static constexpr int kChannels = 2;

  AudioOutput();
  ~AudioOutput();
  AudioOutput(const AudioOutput&) = delete;
  AudioOutput& operator=(const AudioOutput&) = delete;

  /// false when no device could be opened (callers then use a steady clock).
  bool open(Callback cb, void* user, bool null_backend);
  void start();
  void stop();
  bool started() const;

  /// Audio the device buffers after taking it (output latency estimate).
  Ticks latency() const;
  /// Name of the backend in use ("AAudio", "WASAPI", "Null", ...).
  const char* backend() const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace cutlab::media
