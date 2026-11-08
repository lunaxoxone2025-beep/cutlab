#include "audio_output.hpp"

#include <algorithm>

#include "miniaudio.h"

namespace cutlab::media {

struct AudioOutput::Impl {
  ma_context context{};
  bool context_ok = false;
  ma_device device{};
  bool device_ok = false;
  bool started = false;
  Ticks latency = 0;
  Callback cb = nullptr;
  void* user = nullptr;

  static void callback(ma_device* dev, void* out, const void* /*in*/, ma_uint32 frames) {
    auto* self = static_cast<Impl*>(dev->pUserData);
    self->cb(self->user, static_cast<float*>(out), frames);
  }
};

AudioOutput::AudioOutput() : impl_(std::make_unique<Impl>()) {}

AudioOutput::~AudioOutput() {
  if (impl_->device_ok) ma_device_uninit(&impl_->device);
  if (impl_->context_ok) ma_context_uninit(&impl_->context);
}

bool AudioOutput::open(Callback cb, void* user, bool null_backend) {
  Impl& m = *impl_;
  m.cb = cb;
  m.user = user;
  ma_backend null_only[] = {ma_backend_null};
  if (ma_context_init(null_backend ? null_only : nullptr, null_backend ? 1 : 0, nullptr, &m.context) != MA_SUCCESS) return false;
  m.context_ok = true;
  ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
  cfg.playback.format = ma_format_f32;
  cfg.playback.channels = kChannels;
  cfg.sampleRate = kRate;
  cfg.dataCallback = &Impl::callback;
  cfg.pUserData = &m;
  cfg.performanceProfile = ma_performance_profile_low_latency;
  if (ma_device_init(&m.context, &cfg, &m.device) != MA_SUCCESS) return false;
  m.device_ok = true;
  const ma_uint32 buffered = m.device.playback.internalPeriodSizeInFrames * std::max<ma_uint32>(1, m.device.playback.internalPeriods);
  const ma_uint32 rate = m.device.playback.internalSampleRate ? m.device.playback.internalSampleRate : kRate;
  m.latency = mul_div(buffered, kTicksPerSecond, rate, Rounding::Nearest);
  return true;
}

void AudioOutput::start() {
  if (impl_->device_ok && !impl_->started && ma_device_start(&impl_->device) == MA_SUCCESS) impl_->started = true;
}

void AudioOutput::stop() {
  if (impl_->device_ok && impl_->started) {
    ma_device_stop(&impl_->device);
    impl_->started = false;
  }
}

bool AudioOutput::started() const { return impl_->started; }
Ticks AudioOutput::latency() const { return impl_->latency; }
const char* AudioOutput::backend() const {
  return impl_->context_ok ? ma_get_backend_name(impl_->context.backend) : "none";
}

}  // namespace cutlab::media
