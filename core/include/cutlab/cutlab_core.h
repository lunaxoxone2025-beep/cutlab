/* CUTLAB core — stable C ABI.
 *
 * This is the only surface the Flutter app talks to (through dart:ffi).
 * Rules: plain C types only, no exceptions cross the boundary, every call
 * that can fail returns a cutlab_status and writes results to out-params.
 */
#ifndef CUTLAB_CORE_H
#define CUTLAB_CORE_H

#include <stdint.h>

#if defined(_WIN32)
#  if defined(CUTLAB_CORE_BUILD)
#    define CUTLAB_API __declspec(dllexport)
#  else
#    define CUTLAB_API __declspec(dllimport)
#  endif
#else
#  define CUTLAB_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef enum cutlab_status {
  CUTLAB_OK = 0,
  CUTLAB_ERR_INVALID_ARGUMENT = 1,
  CUTLAB_ERR_OVERFLOW = 2,
  CUTLAB_ERR_INTERNAL = 99
} cutlab_status;

typedef enum cutlab_rounding {
  CUTLAB_ROUND_DOWN = 0,
  CUTLAB_ROUND_UP = 1,
  CUTLAB_ROUND_NEAREST = 2
} cutlab_rounding;

/* Library version, e.g. "0.1.0". Static string, never free it. */
CUTLAB_API const char* cutlab_core_version(void);

/* Ticks per second used by every stored time value (705600000). */
CUTLAB_API int64_t cutlab_ticks_per_second(void);

CUTLAB_API cutlab_status cutlab_rescale(int64_t value, int64_t from_num, int64_t from_den, int64_t to_num,
                                        int64_t to_den, cutlab_rounding rounding, int64_t* out);

CUTLAB_API cutlab_status cutlab_frames_to_ticks(int64_t frame, int64_t fps_num, int64_t fps_den, int64_t* out_ticks);

CUTLAB_API cutlab_status cutlab_ticks_to_frames(int64_t ticks, int64_t fps_num, int64_t fps_den,
                                                cutlab_rounding rounding, int64_t* out_frame);

#ifdef __cplusplus
}
#endif

#endif /* CUTLAB_CORE_H */
