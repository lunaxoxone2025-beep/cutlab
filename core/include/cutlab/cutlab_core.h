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
  CUTLAB_ERR_MEDIA = 3,          /* cannot open/decode the media; see cutlab_last_error() */
  CUTLAB_ERR_UNAVAILABLE = 4,    /* built without the media engine */
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

/* ------------------------------------------------------------------ media
 *
 * Media is addressed by a UTF-8 path, or "fd:<n>" for an open file
 * descriptor (Android content:// URIs). Descriptors are duplicated
 * internally; the caller keeps and eventually closes its own.
 *
 * Calls that decode (probe, frame, thumbnails, peaks) block: run them on a
 * background thread/isolate. Player calls are cheap and never block on I/O.
 */

/* Message for the last failed call on this thread. Never free it. */
CUTLAB_API const char* cutlab_last_error(void);

/* Frees memory returned by the media API (JSON strings, pixel/peak buffers). */
CUTLAB_API void cutlab_free(void* p);

/* JSON: {"ffmpeg": "...", "hardwareDecoders": [...], "mediaEngine": true} */
CUTLAB_API cutlab_status cutlab_engine_info(char** out_json);

/* JSON description of a media file (see docs/ENGINE.md). */
CUTLAB_API cutlab_status cutlab_media_probe(const char* uri, char** out_json);

/* The frame displayed at `ticks` (accurate != 0) or the keyframe before it,
 * as RGBA rows of width*4 bytes, fitted inside max_w x max_h (0 = no limit). */
CUTLAB_API cutlab_status cutlab_media_frame(const char* uri, int64_t ticks, int32_t max_w, int32_t max_h, int32_t accurate,
                                            uint8_t** out_rgba, int32_t* out_w, int32_t* out_h, int64_t* out_pts);

/* `count` keyframe thumbnails spread over the whole duration, all the same
 * size, concatenated in out_rgba; out_pts receives `count` timestamps.
 * Cost depends on `count`, not on the file length. */
CUTLAB_API cutlab_status cutlab_media_thumbnails(const char* uri, int32_t count, int32_t max_w, int32_t max_h,
                                                 uint8_t** out_rgba, int32_t* out_w, int32_t* out_h, int32_t* out_count,
                                                 int64_t* out_pts);

/* Waveform: min/max float pairs, buckets_per_second per second (mono).
 * *cancel != 0 stops early; *progress receives 0..1000. Both may be NULL. */
CUTLAB_API cutlab_status cutlab_media_peaks(const char* uri, int32_t buckets_per_second, const volatile int32_t* cancel,
                                            volatile int32_t* progress, float** out_pairs, int64_t* out_pair_count);

/* Closes a file descriptor (helper for Android callers). */
CUTLAB_API void cutlab_close_fd(int32_t fd);

/* ----------------------------------------------------------------- player */

typedef struct cutlab_player cutlab_player;

enum {
  CUTLAB_PLAYER_SOFTWARE_DECODE = 1, /* do not try hardware decoding */
  CUTLAB_PLAYER_NULL_AUDIO = 2       /* consume audio without a sound device (tests) */
};

CUTLAB_API cutlab_status cutlab_player_open(const char* uri, int32_t max_w, int32_t max_h, int32_t flags, cutlab_player** out);
CUTLAB_API void cutlab_player_close(cutlab_player* p);
CUTLAB_API void cutlab_player_play(cutlab_player* p);
CUTLAB_API void cutlab_player_pause(cutlab_player* p);
CUTLAB_API int32_t cutlab_player_playing(cutlab_player* p);
CUTLAB_API void cutlab_player_seek(cutlab_player* p, int64_t ticks, int32_t accurate);
CUTLAB_API int64_t cutlab_player_position(cutlab_player* p);
CUTLAB_API int64_t cutlab_player_duration(cutlab_player* p);

/* Copies the frame due now into dst when it differs from *serial (returns 1
 * and updates *serial). out_w/out_h are set even when dst is too small. */
CUTLAB_API int32_t cutlab_player_frame(cutlab_player* p, uint64_t* serial, uint8_t* dst, int64_t capacity, int32_t* out_w,
                                       int32_t* out_h, int64_t* out_pts);

/* JSON playback statistics (decoder, hardware, dropped frames, buffers,
 * hardwareFallback, error, memory). */
CUTLAB_API cutlab_status cutlab_player_stats(cutlab_player* p, char** out_json);

/* --------------------------------------------------------------- timeline */

/* Real-time playback of an edited timeline: picture of the top-most visible
 * clip, all audible clips mixed (clip volume × fades × track volume, mute,
 * solo, master), clocked by the audio device. See docs/PLAYBACK.md. */
typedef struct cutlab_timeline cutlab_timeline;

/* flags: CUTLAB_PLAYER_NULL_AUDIO (no sound device; tests). */
CUTLAB_API cutlab_status cutlab_timeline_open(int32_t max_w, int32_t max_h, int32_t flags, cutlab_timeline** out);
CUTLAB_API void cutlab_timeline_close(cutlab_timeline* t);

/* Replaces what is played (plan text, see docs/PLAYBACK.md). Playback goes
 * on; mix-only changes do not disturb the picture. */
CUTLAB_API cutlab_status cutlab_timeline_set_plan(cutlab_timeline* t, const char* plan);
CUTLAB_API void cutlab_timeline_play(cutlab_timeline* t);
CUTLAB_API void cutlab_timeline_pause(cutlab_timeline* t);
CUTLAB_API int32_t cutlab_timeline_playing(cutlab_timeline* t);
CUTLAB_API void cutlab_timeline_seek(cutlab_timeline* t, int64_t ticks, int32_t accurate);
CUTLAB_API int64_t cutlab_timeline_position(cutlab_timeline* t);
CUTLAB_API int64_t cutlab_timeline_duration(cutlab_timeline* t);

/* Like cutlab_player_frame; out_w = out_h = 0 with return 1 means black. */
CUTLAB_API int32_t cutlab_timeline_frame(cutlab_timeline* t, uint64_t* serial, uint8_t* dst, int64_t capacity, int32_t* out_w,
                                         int32_t* out_h, int64_t* out_pts);

/* Peak levels of what is heard now: one per track (plan order), then the
 * master. Returns the number written. */
CUTLAB_API int32_t cutlab_timeline_levels(cutlab_timeline* t, float* out, int32_t capacity);

/* JSON: position, underruns, A/V lateness, audio clock drift, mixer load,
 * decoders, dropped frames, errors. */
CUTLAB_API cutlab_status cutlab_timeline_stats(cutlab_timeline* t, char** out_json);

/* Renders the mix offline (no device, independent of playback): `frames`
 * stereo frames at 48 kHz from start_ticks into out (frames * 2 floats).
 * peaks (optional): per track then master. For tests and export. */
CUTLAB_API cutlab_status cutlab_timeline_render_audio(cutlab_timeline* t, int64_t start_ticks, int32_t frames, float* out, float* peaks,
                                                      int32_t peaks_capacity);

/* --------------------------------------------------- effects / composing */

/* Composes the picture of a timeline plan at `ticks` (effects, video fades,
 * transitions; no titles) at width x height RGBA into dst (capacity >= w*h*4),
 * exactly as the export does before encoding and the preview does at
 * preview size. Independent of any player. For tests and checks. */
CUTLAB_API cutlab_status cutlab_render_frame(const char* plan, int64_t ticks, int32_t width, int32_t height, uint8_t* dst, int64_t capacity);

/* The effect types and their parameters as JSON:
 * {"effects":[{"type","params":[{"name","min","max","default"}]}],
 *  "looks":[...], "transitions":[...], "directions":[...]}. */
CUTLAB_API cutlab_status cutlab_effect_catalog(char** out_json);

/* ----------------------------------------------------------------- export
 *
 * Renders a timeline plan (the playback plan plus "duration" and title
 * "overlay" lines) to a video file in a background thread. settings is
 * "key value" lines: path, container, video, encoder, size, fps, quality,
 * bitrate, speed, hardware, keyframes, audio, audio_bitrate, threads
 * (docs/EXPORT.md). The file is written as <path>.part and renamed when
 * complete; a cancelled or failed export leaves nothing behind.
 */
typedef struct cutlab_export cutlab_export;

CUTLAB_API cutlab_status cutlab_export_start(const char* plan, const char* settings, cutlab_export** out);
CUTLAB_API void cutlab_export_pause(cutlab_export* e, int32_t paused);
CUTLAB_API void cutlab_export_cancel(cutlab_export* e);
/* JSON: state (preparing|rendering|finishing|done|failed|cancelled), paused,
 * framesDone, framesTotal, progress, elapsedMs, fps, speed, etaMs, bytes,
 * encoder, hardware, audioEncoder, restarts, decodeErrors, error, warnings. */
CUTLAB_API cutlab_status cutlab_export_status(cutlab_export* e, char** out_json);
/* Cancels if still running, waits for the worker and frees. */
CUTLAB_API void cutlab_export_close(cutlab_export* e);

/* Encoders in this build, best first per codec, as a JSON array of
 * {codec, name, hardware, usable, note}. probe != 0 test-encodes with every
 * hardware encoder (on Android, run it in the separate test process). */
CUTLAB_API cutlab_status cutlab_export_encoders(int32_t probe, char** out_json);

/* ------------------------------------------------------------ diagnostics */

/* Tries hardware decoding of a file (decodes ~50 frames with seeks).
 * JSON: {"ok", "decoder", "hardware", "stillHardware", "frames", "fallback"}.
 * On Android the app runs this in a separate process first, so a broken
 * vendor decoder cannot take the editor down. */
CUTLAB_API cutlab_status cutlab_hw_self_test(const char* uri, char** out_json);

/* Installs the native crash handler (reports go to <dir>/native-crash.txt,
 * with device_info, memory figures, a backtrace and recent engine activity)
 * and routes FFmpeg warnings into the activity log. */
CUTLAB_API cutlab_status cutlab_diag_init(const char* dir, const char* device_info);

/* Adds a line to the engine activity log. */
CUTLAB_API void cutlab_diag_note(const char* text);

/* Recent engine activity plus current memory use (free with cutlab_free). */
CUTLAB_API cutlab_status cutlab_diag_recent(char** out_text);

#ifdef __cplusplus
}
#endif

#endif /* CUTLAB_CORE_H */
