// C ABI for the media engine.
#include <cstdlib>
#include <cstring>
#include <string>
#include <mutex>
#include <thread>

#include "../diag/diag.hpp"
#include "audio_decoder.hpp"
#include "compositor.hpp"
#include "export.hpp"
#include "cutlab/cutlab_core.h"
#include "json.hpp"
#include "player.hpp"
#include "probe.hpp"
#include "timeline.hpp"
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

// Player calls must never throw across the C boundary (that would end the app).
template <typename F, typename R>
R safe(F&& fn, R fallback) {
  try {
    return fn();
  } catch (...) {
    return fallback;
  }
}

}  // namespace

namespace cutlab::media {

std::string hardware_self_test(const Source& src) {
  DecodeOptions o;
  o.prefer_hardware = true;
  o.max_width = 640;
  o.max_height = 640;
  VideoDecoder dec(src, o);
  const bool started_hw = dec.hardware();
  const std::string first_decoder = dec.decoder_name();
  VideoFrame f;
  int frames = 0;
  dec.seek(0, true);
  for (int i = 0; i < 45 && dec.next(f); ++i) ++frames;
  const Ticks dur = dec.duration();
  if (dur > 0) {
    if (dec.frame_at(dur / 2, f, true)) ++frames;
    dec.seek(dur * 9 / 10, false);
    for (int i = 0; i < 5 && dec.next(f); ++i) ++frames;
  }
  JsonWriter j;
  j.begin_object();
  j.key("ok").value(started_hw && dec.hardware() && frames > 0);
  j.key("decoder").value(first_decoder);
  j.key("hardware").value(started_hw);
  j.key("stillHardware").value(dec.hardware());
  j.key("frames").value(frames);
  j.key("fallback").value(dec.hardware_fallback());
  j.end_object();
  diag::note("hardware self-test %s: decoder=%s frames=%d hw=%d fallback=%s", src.describe().c_str(), first_decoder.c_str(), frames,
             dec.hardware() ? 1 : 0, dec.hardware_fallback().c_str());
  return j.str();
}

}  // namespace cutlab::media

struct cutlab_timeline {
  TimelinePlayer player;
  std::mutex offline_mu;
  Mixer offline;  // render_audio(): independent of playback
  explicit cutlab_timeline(TimelineOptions o) : player(o) {}
};

struct cutlab_export {
  std::shared_ptr<Exporter> exporter;
  cutlab_export(std::shared_ptr<const TlPlan> plan, ExportSettings s) : exporter(Exporter::start(std::move(plan), std::move(s))) {}
  ~cutlab_export() {
    exporter->cancel();
    // Normally done at once; an encoder stuck inside its library keeps its
    // thread (and the exporter) until it returns, without blocking the app.
    if (!exporter->wait_for(3000)) diag::note("export: the worker did not stop in 3 s; left to finish on its own");
  }
};

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
    j.key("cpus").value(static_cast<int64_t>(std::thread::hardware_concurrency()));
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
    o.one_shot = true;
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

void cutlab_player_close(cutlab_player* p) {
  try {
    delete p;
  } catch (...) {
    // Destructors join threads; nothing to recover here.
  }
}
void cutlab_player_play(cutlab_player* p) {
  if (p) safe([&] { p->player.play(); return 0; }, 0);
}
void cutlab_player_pause(cutlab_player* p) {
  if (p) safe([&] { p->player.pause(); return 0; }, 0);
}
int32_t cutlab_player_playing(cutlab_player* p) { return p ? safe([&] { return p->player.playing() ? 1 : 0; }, 0) : 0; }
void cutlab_player_seek(cutlab_player* p, int64_t ticks, int32_t accurate) {
  if (p) safe([&] { p->player.seek(ticks, accurate != 0); return 0; }, 0);
}
int64_t cutlab_player_position(cutlab_player* p) { return p ? safe([&] { return p->player.position(); }, int64_t{0}) : 0; }
int64_t cutlab_player_duration(cutlab_player* p) { return p ? safe([&] { return p->player.duration(); }, int64_t{0}) : 0; }

int32_t cutlab_player_frame(cutlab_player* p, uint64_t* serial, uint8_t* dst, int64_t capacity, int32_t* out_w, int32_t* out_h,
                            int64_t* out_pts) {
  if (!p || !serial) return 0;
  return safe(
      [&]() -> int32_t {
        int w = 0, h = 0;
        Ticks pts = 0;
        const bool ok = p->player.frame(serial, dst, capacity > 0 ? static_cast<size_t>(capacity) : 0, &w, &h, &pts);
        if (out_w) *out_w = w;
        if (out_h) *out_h = h;
        if (out_pts) *out_pts = pts;
        return ok ? 1 : 0;
      },
      int32_t{0});
}

cutlab_status cutlab_player_stats(cutlab_player* p, char** out_json) {
  if (!p || !out_json) return CUTLAB_ERR_INVALID_ARGUMENT;
  return guarded([&] {
    *out_json = dup_string(p->player.stats_json());
    if (!*out_json) throw std::bad_alloc();
  });
}

cutlab_status cutlab_timeline_open(int32_t max_w, int32_t max_h, int32_t flags, cutlab_timeline** out) {
  if (!out) return CUTLAB_ERR_INVALID_ARGUMENT;
  return guarded([&] {
    TimelineOptions o;
    if (max_w > 0) o.max_width = max_w;
    if (max_h > 0) o.max_height = max_h;
    o.null_audio_device = (flags & CUTLAB_PLAYER_NULL_AUDIO) != 0;
    *out = new cutlab_timeline(o);
  });
}

void cutlab_timeline_close(cutlab_timeline* t) {
  try {
    delete t;
  } catch (...) {
  }
}

cutlab_status cutlab_timeline_set_plan(cutlab_timeline* t, const char* plan) {
  if (!t || !plan) return CUTLAB_ERR_INVALID_ARGUMENT;
  return guarded([&] { t->player.set_plan(std::make_shared<const TlPlan>(TlPlan::parse(plan))); });
}

void cutlab_timeline_play(cutlab_timeline* t) {
  if (t) safe([&] { t->player.play(); return 0; }, 0);
}
void cutlab_timeline_pause(cutlab_timeline* t) {
  if (t) safe([&] { t->player.pause(); return 0; }, 0);
}
int32_t cutlab_timeline_playing(cutlab_timeline* t) { return t ? safe([&] { return t->player.playing() ? 1 : 0; }, 0) : 0; }
void cutlab_timeline_seek(cutlab_timeline* t, int64_t ticks, int32_t accurate) {
  if (t) safe([&] { t->player.seek(ticks, accurate != 0); return 0; }, 0);
}
int64_t cutlab_timeline_position(cutlab_timeline* t) { return t ? safe([&] { return t->player.position(); }, int64_t{0}) : 0; }
int64_t cutlab_timeline_duration(cutlab_timeline* t) { return t ? safe([&] { return t->player.duration(); }, int64_t{0}) : 0; }

int32_t cutlab_timeline_frame(cutlab_timeline* t, uint64_t* serial, uint8_t* dst, int64_t capacity, int32_t* out_w, int32_t* out_h,
                              int64_t* out_pts) {
  if (!t || !serial) return 0;
  return safe(
      [&]() -> int32_t {
        int w = 0, h = 0;
        Ticks pts = 0;
        const bool ok = t->player.frame(serial, dst, capacity > 0 ? static_cast<size_t>(capacity) : 0, &w, &h, &pts);
        if (out_w) *out_w = w;
        if (out_h) *out_h = h;
        if (out_pts) *out_pts = pts;
        return ok ? 1 : 0;
      },
      int32_t{0});
}

int32_t cutlab_timeline_levels(cutlab_timeline* t, float* out, int32_t capacity) {
  if (!t || !out || capacity <= 0) return 0;
  return safe([&] { return static_cast<int32_t>(t->player.levels(out, static_cast<size_t>(capacity))); }, int32_t{0});
}

cutlab_status cutlab_timeline_stats(cutlab_timeline* t, char** out_json) {
  if (!t || !out_json) return CUTLAB_ERR_INVALID_ARGUMENT;
  return guarded([&] {
    *out_json = dup_string(t->player.stats_json());
    if (!*out_json) throw std::bad_alloc();
  });
}

cutlab_status cutlab_timeline_render_audio(cutlab_timeline* t, int64_t start_ticks, int32_t frames, float* out, float* peaks,
                                           int32_t peaks_capacity) {
  if (!t || !out || frames <= 0) return CUTLAB_ERR_INVALID_ARGUMENT;
  return guarded([&] {
    auto plan = t->player.plan();
    std::vector<float> p(plan->tracks.size() + 1, 0.0f);
    std::lock_guard<std::mutex> lock(t->offline_mu);
    t->offline.render(*plan, ticks_to_samples(start_ticks), static_cast<size_t>(frames), out, p.data(), &p.back());
    if (peaks) {
      for (int32_t i = 0; i < peaks_capacity && i < static_cast<int32_t>(p.size()); ++i) peaks[i] = p[static_cast<size_t>(i)];
    }
  });
}

cutlab_status cutlab_render_frame(const char* plan, int64_t ticks, int32_t width, int32_t height, uint8_t* dst, int64_t capacity) {
  if (!plan || !dst || width < 2 || height < 2 || width > 16384 || height > 16384) return CUTLAB_ERR_INVALID_ARGUMENT;
  if (capacity < static_cast<int64_t>(width) * height * 4) return CUTLAB_ERR_INVALID_ARGUMENT;
  return guarded([&] {
    const TlPlan p = TlPlan::parse(plan);
    DecodeOptions o;
    o.prefer_hardware = p.hardware;
    o.one_shot = true;
    Compositor c(width, height, o);
    bool black = false;
    c.render(p, ticks, &black);
    std::memcpy(dst, c.picture().px.data(), static_cast<size_t>(width) * height * 4);
  });
}

cutlab_status cutlab_effect_catalog(char** out_json) {
  if (!out_json) return CUTLAB_ERR_INVALID_ARGUMENT;
  return guarded([&] {
    JsonWriter j;
    j.begin_object();
    j.key("effects").begin_array();
    for (const auto& e : effect_catalog()) {
      j.begin_object();
      j.key("type").value(e.type);
      j.key("params").begin_array();
      for (const auto& p : e.params) {
        j.begin_object();
        j.key("name").value(p.name);
        j.key("min").value(p.lo);
        j.key("max").value(p.hi);
        j.key("default").value(p.def);
        j.end_object();
      }
      j.end_array();
      j.end_object();
    }
    j.end_array();
    j.key("looks").begin_array();
    for (const auto& l : filter_looks()) j.value(l);
    j.end_array();
    j.key("transitions").begin_array();
    for (const char* t : {"dissolve", "dip_black", "dip_white", "wipe", "slide", "zoom_in", "zoom_out", "blur"}) j.value(t);
    j.end_array();
    j.key("directions").begin_array();
    for (const char* d : {"left", "right", "up", "down"}) j.value(d);
    j.end_array();
    j.end_object();
    *out_json = dup_string(j.str());
    if (!*out_json) throw std::bad_alloc();
  });
}

cutlab_status cutlab_export_start(const char* plan, const char* settings, cutlab_export** out) {
  if (!plan || !settings || !out) return CUTLAB_ERR_INVALID_ARGUMENT;
  *out = nullptr;
  return guarded([&] {
    auto p = std::make_shared<const TlPlan>(TlPlan::parse(plan));
    ExportSettings s = ExportSettings::parse(settings);
    *out = new cutlab_export(std::move(p), std::move(s));
  });
}

void cutlab_export_pause(cutlab_export* e, int32_t paused) {
  if (e) safe([&] { e->exporter->pause(paused != 0); return 0; }, 0);
}

void cutlab_export_cancel(cutlab_export* e) {
  if (e) safe([&] { e->exporter->cancel(); return 0; }, 0);
}

cutlab_status cutlab_export_status(cutlab_export* e, char** out_json) {
  if (!e || !out_json) return CUTLAB_ERR_INVALID_ARGUMENT;
  return guarded([&] {
    *out_json = dup_string(e->exporter->status_json());
    if (!*out_json) throw std::bad_alloc();
  });
}

void cutlab_export_close(cutlab_export* e) {
  safe([&] {
    delete e;
    return 0;
  }, 0);
}

cutlab_status cutlab_export_encoders(int32_t probe, char** out_json) {
  if (!out_json) return CUTLAB_ERR_INVALID_ARGUMENT;
  return guarded([&] {
    *out_json = dup_string(encoders_json(available_encoders(probe != 0)));
    if (!*out_json) throw std::bad_alloc();
  });
}

cutlab_status cutlab_hw_self_test(const char* uri, char** out_json) {
  if (!out_json) return CUTLAB_ERR_INVALID_ARGUMENT;
  return guarded([&] {
    *out_json = dup_string(hardware_self_test(source_of(uri)));
    if (!*out_json) throw std::bad_alloc();
  });
}

cutlab_status cutlab_diag_init(const char* dir, const char* device_info) {
  return guarded([&] { diag::init(dir ? dir : "", device_info ? device_info : ""); });
}

void cutlab_diag_note(const char* text) {
  if (text) diag::note("%s", text);
}

cutlab_status cutlab_diag_recent(char** out_text) {
  if (!out_text) return CUTLAB_ERR_INVALID_ARGUMENT;
  return guarded([&] {
    int64_t rss = 0, peak = 0;
    diag::memory_kib(&rss, &peak);
    std::string text = diag::recent();
    text += "memory: rss " + std::to_string(rss / 1024) + " MB, peak " + std::to_string(peak / 1024) + " MB; hardware decoders open: " +
            std::to_string(diag::hardware_decoders_open()) + "\n";
    *out_text = dup_string(text);
    if (!*out_text) throw std::bad_alloc();
  });
}

}  // extern "C"
