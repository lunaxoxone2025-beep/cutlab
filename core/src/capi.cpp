#include "cutlab/cutlab_core.h"

#include <stdexcept>

#include "cutlab/time.hpp"

#ifndef CUTLAB_CORE_VERSION
#define CUTLAB_CORE_VERSION "0.0.0"
#endif

namespace {

cutlab::Rounding to_rounding(cutlab_rounding r) {
  switch (r) {
    case CUTLAB_ROUND_DOWN: return cutlab::Rounding::Down;
    case CUTLAB_ROUND_UP: return cutlab::Rounding::Up;
    case CUTLAB_ROUND_NEAREST: return cutlab::Rounding::Nearest;
  }
  throw std::invalid_argument("rounding");
}

template <typename F>
cutlab_status guard(int64_t* out, F&& fn) {
  if (!out) return CUTLAB_ERR_INVALID_ARGUMENT;
  try {
    *out = fn();
    return CUTLAB_OK;
  } catch (const std::invalid_argument&) {
    return CUTLAB_ERR_INVALID_ARGUMENT;
  } catch (const std::overflow_error&) {
    return CUTLAB_ERR_OVERFLOW;
  } catch (...) {
    return CUTLAB_ERR_INTERNAL;
  }
}

}  // namespace

extern "C" {

const char* cutlab_core_version(void) { return CUTLAB_CORE_VERSION; }

int64_t cutlab_ticks_per_second(void) { return cutlab::kTicksPerSecond; }

cutlab_status cutlab_rescale(int64_t value, int64_t from_num, int64_t from_den, int64_t to_num, int64_t to_den,
                             cutlab_rounding rounding, int64_t* out) {
  return guard(out, [&] {
    return cutlab::rescale(value, cutlab::Rational::make(from_num, from_den), cutlab::Rational::make(to_num, to_den),
                           to_rounding(rounding));
  });
}

cutlab_status cutlab_frames_to_ticks(int64_t frame, int64_t fps_num, int64_t fps_den, int64_t* out_ticks) {
  return guard(out_ticks, [&] { return cutlab::frames_to_ticks(frame, cutlab::Rational::make(fps_num, fps_den)); });
}

cutlab_status cutlab_ticks_to_frames(int64_t ticks, int64_t fps_num, int64_t fps_den, cutlab_rounding rounding,
                                     int64_t* out_frame) {
  return guard(out_frame, [&] {
    return cutlab::ticks_to_frames(ticks, cutlab::Rational::make(fps_num, fps_den), to_rounding(rounding));
  });
}

}  // extern "C"
