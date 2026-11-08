// C ABI for the media engine.
#include <cstdlib>
#include <cstring>
#include <string>

#include "audio_decoder.hpp"
#include "cutlab/cutlab_core.h"
#include "json.hpp"
#include "player.hpp"
#include "probe.hpp"
#include "video_decoder.hpp"

#ifndef _WIN32
#include <unistd.h>
#endif

using namespace cutlab;
using namespace cutlab::media;

namespace {

thread_local std::string g_last_error;

char* dup_string(const std::string& s) {
  char* p = static_cast<char*>(std::malloc(s.size() + 1));
  if (p) std::memcpy(p, s.c_str(), s.size() + 1);
  return p;
}

template <typename F>
cutlab_status guarded(F&& fn) {
  try {
    fn();
    g_last_error.clear();
    return CUTLAB_OK;
  } catch (const MediaError& e) {
    g_last_error = e.what();
    return CUTLAB_ERR_MEDIA;
  } catch (const std::invalid_argument& e) {
    g_last_error = e.what();
    return CUTLAB_ERR_INVALID_ARGUMENT;
  } catch (const std::overflow_error& e) {
    g_last_error = e.what();
    return CUTLAB_ERR_OVERFLOW;
  } catch (const std::bad_alloc&) {
    g_last_error = "out of memory";
    return CUTLAB_ERR_INTERNAL;
  } catch (const std::exception& e) {
    g_last_error = e.what();
    return CUTLAB_ERR_INTERNAL;
  } catch (...) {
    g_last_error = "unknown error";
    return CUTLAB_ERR_INTERNAL;
  }
}

Source source_of(const char* uri) {
  if (!uri) throw std::invalid_argument("uri is null");
  return Source::parse(uri);
}

}  // namespace

struct cutlab_player {
  Player player;
  cutlab_player(const Source& s, PlayerOptions o) : player(s, o) {}
};

extern "C" {

const char* cutlab_last_error(void) { return g_last_error.c_str(); }

void cutlab_free(void* p) { std::free(p); }

void cutlab_close_fd(int32_t fd) {
#ifndef _WIN32
  if (fd >= 0) ::close(fd);
#else
  (void)fd;
#endif
}

cutlab_status cutlab_engine_info(char** out_json) {
  if (!out_json) return CUTLAB_ERR_INVALID_ARGUMENT;
  return guarded([&] {
    JsonWriter j;
    j.begin_object();
    j.key("mediaEngine").value(true);
    j.key("ffmpeg").value(av_version_info());
    j.key("hardwareDecoders").begin_array();
#ifdef __ANDROID__
    for (const char* name : {"h264_mediacodec", "hevc_mediacodec", "vp9_mediacodec", "av1_mediacodec"}) {
      if (avcodec_find_decoder_by_name(name)) j.value(name);
    }
#else
    for (AVHWDeviceType t = av_hwdevice_iterate_types(AV_HWDEVICE_TYPE_NONE); t != AV_HWDEVICE_TYPE_NONE;
         t = av_hwdevice_iterate_types(t)) {
      j.value(av_hwdevice_get_type_name(t));
    }
#endif
    j.end_array();
    j.end_object();
    *out_json = dup_string(j.str());
    if (!*out_json) throw std::bad_alloc();
  });
}

cutlab_status cutlab_media_probe(const char* uri, char** out_json) {
  if (!out_json) return CUTLAB_ERR_INVALID_ARGUMENT;
  return guarded([&] {
    const ProbeResult r = probe(source_of(uri));
    *out_json = dup_string(r.to_json());
    if (!*out_json) throw std::bad_alloc();
  });
}

cutlab_status cutlab_media_frame(const char* uri, int64_t ticks, int32_t max_w, int32_t max_h, int32_t accurate, uint8_t** out_rgba,
                                 int32_t* out_w, int32_t* out_h, int64_t* out_pts) {
  if (!out_rgba || !out_w || !out_h) return CUTLAB_ERR_INVALID_ARGUMENT;
  return guarded([&] {
    DecodeOptions o;
    o.max_width = max_w;
    o.max_height = max_h;
    VideoDecoder dec(source_of(uri), o);
    VideoFrame f;
    if (!dec.frame_at(ticks, f, accurate != 0)) throw MediaError("no frame at that time");
    auto* buf = static_cast<uint8_t*>(std::malloc(f.rgba.size()));
    if (!buf) throw std::bad_alloc();
    std::memcpy(buf, f.rgba.data(), f.rgba.size());
    *out_rgba = buf;
    *out_w = f.width;
    *out_h = f.height;
    if (out_pts) *out_pts = f.pts;
  });
}

cutlab_status cutlab_media_thumbnails(const char* uri, int32_t count, int32_t max_w, int32_t max_h, uint8_t** out_rgba, int32_t* out_w,
                                      int32_t* out_h, int32_t* out_count, int64_t* out_pts) {
  if (!out_rgba || !out_w || !out_h || !out_count || count <= 0 || count > 1000) return CUTLAB_ERR_INVALID_ARGUMENT;
  return guarded([&] {
    DecodeOptions o;
    o.max_width = max_w;
    o.max_height = max_h;
    o.keyframes_only = true;
    VideoDecoder dec(source_of(uri), o);
    const Ticks dur = dec.duration();
    std::vector<VideoFrame> frames;
    frames.reserve(static_cast<size_t>(count));
    for (int i = 0; i < count; ++i) {
      const Ticks t = dur > 0 ? mul_div(dur, 2 * i + 1, 2 * static_cast<int64_t>(count), Rounding::Down) : 0;
      VideoFrame f;
      if (dec.frame_at(t, f, false)) {
        frames.push_back(std::move(f));
      } else if (!frames.empty()) {
        frames.push_back(frames.back());  // past the last keyframe: repeat it
      }
      if (dec.still_image()) break;
    }
    if (frames.empty()) throw MediaError("no decodable frames");
    // All thumbnails share the first one's size (the stream size can change mid-file).
    const int w = frames[0].width, h = frames[0].height;
    const size_t each = static_cast<size_t>(w) * h * 4;
    auto* buf = static_cast<uint8_t*>(std::malloc(each * frames.size()));
    if (!buf) throw std::bad_alloc();
    for (size_t i = 0; i < frames.size(); ++i) {
      if (frames[i].rgba.size() == each) {
        std::memcpy(buf + i * each, frames[i].rgba.data(), each);
      } else {
        std::memset(buf + i * each, 0, each);
      }
      if (out_pts) out_pts[i] = frames[i].pts;
    }
    *out_rgba = buf;
    *out_w = w;
    *out_h = h;
    *out_count = static_cast<int32_t>(frames.size());
  });
}

cutlab_status cutlab_media_peaks(const char* uri, int32_t buckets_per_second, const volatile int32_t* cancel, volatile int32_t* progress,
                                 float** out_pairs, int64_t* out_pair_count) {
  if (!out_pairs || !out_pair_count) return CUTLAB_ERR_INVALID_ARGUMENT;
  return guarded([&] {
    const std::vector<float> peaks = compute_peaks(source_of(uri), buckets_per_second, cancel, progress);
    auto* buf = static_cast<float*>(std::malloc(std::max<size_t>(1, peaks.size()) * sizeof(float)));
    if (!buf) throw std::bad_alloc();
    if (!peaks.empty()) std::memcpy(buf, peaks.data(), peaks.size() * sizeof(float));
    *out_pairs = buf;
    *out_pair_count = static_cast<int64_t>(peaks.size() / 2);
  });
}

cutlab_status cutlab_player_open(const char* uri, int32_t max_w, int32_t max_h, int32_t flags, cutlab_player** out) {
  if (!out) return CUTLAB_ERR_INVALID_ARGUMENT;
  return guarded([&] {
    PlayerOptions o;
    if (max_w > 0) o.max_width = max_w;
    if (max_h > 0) o.max_height = max_h;
    o.prefer_hardware = (flags & CUTLAB_PLAYER_SOFTWARE_DECODE) == 0;
    o.null_audio_device = (flags & CUTLAB_PLAYER_NULL_AUDIO) != 0;
    *out = new cutlab_player(source_of(uri), o);
  });
}

void cutlab_player_close(cutlab_player* p) { delete p; }
void cutlab_player_play(cutlab_player* p) {
  if (p) p->player.play();
}
void cutlab_player_pause(cutlab_player* p) {
  if (p) p->player.pause();
}
int32_t cutlab_player_playing(cutlab_player* p) { return p && p->player.playing() ? 1 : 0; }
void cutlab_player_seek(cutlab_player* p, int64_t ticks, int32_t accurate) {
  if (p) p->player.seek(ticks, accurate != 0);
}
int64_t cutlab_player_position(cutlab_player* p) { return p ? p->player.position() : 0; }
int64_t cutlab_player_duration(cutlab_player* p) { return p ? p->player.duration() : 0; }

int32_t cutlab_player_frame(cutlab_player* p, uint64_t* serial, uint8_t* dst, int64_t capacity, int32_t* out_w, int32_t* out_h,
                            int64_t* out_pts) {
  if (!p || !serial) return 0;
  int w = 0, h = 0;
  Ticks pts = 0;
  const bool ok = p->player.frame(serial, dst, capacity > 0 ? static_cast<size_t>(capacity) : 0, &w, &h, &pts);
  if (out_w) *out_w = w;
  if (out_h) *out_h = h;
  if (out_pts) *out_pts = pts;
  return ok ? 1 : 0;
}

cutlab_status cutlab_player_stats(cutlab_player* p, char** out_json) {
  if (!p || !out_json) return CUTLAB_ERR_INVALID_ARGUMENT;
  return guarded([&] {
    *out_json = dup_string(p->player.stats_json());
    if (!*out_json) throw std::bad_alloc();
  });
}

}  // extern "C"
