#include "export.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>

#include "../diag/diag.hpp"
#include "json.hpp"

extern "C" {
#include <libavutil/channel_layout.h>
#include <libavutil/pixdesc.h>
}

namespace cutlab::media {
namespace {

using Clock = std::chrono::steady_clock;

struct Cancelled {};

// ----------------------------------------------------------- settings

std::string lower(std::string s) {
  for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return s;
}

int64_t parse_int(const std::string& v, const std::string& key) {
  try {
    size_t used = 0;
    const long long n = std::stoll(v, &used);
    if (used != v.size()) throw std::invalid_argument(v);
    return n;
  } catch (const std::exception&) {
    throw std::invalid_argument("export settings: bad number for " + key + ": '" + v + "'");
  }
}

// ----------------------------------------------------------- encoders

struct Candidate {
  const char* codec;
  const char* name;
  bool hardware;
};

// Best first. Hardware encoders are tried only when they exist in the build
// and open on this machine; the software ones are the fallback.
constexpr Candidate kCandidates[] = {
    {"h264", "h264_nvenc", true},   {"h264", "h264_qsv", true},   {"h264", "h264_amf", true},     {"h264", "h264_mf", true},
    {"h264", "h264_mediacodec", true}, {"h264", "libopenh264", false},
    {"hevc", "hevc_nvenc", true},   {"hevc", "hevc_qsv", true},   {"hevc", "hevc_amf", true},     {"hevc", "hevc_mf", true},
    {"hevc", "hevc_mediacodec", true}, {"hevc", "libkvazaar", false},
    {"vp9", "vp9_qsv", true},       {"vp9", "vp9_mediacodec", true}, {"vp9", "libvpx-vp9", false},
    {"av1", "av1_nvenc", true},     {"av1", "av1_qsv", true},     {"av1", "av1_amf", true},       {"av1", "av1_mf", true},
    {"av1", "av1_mediacodec", true}, {"av1", "libsvtav1", false},  {"av1", "libaom-av1", false},
    {"mpeg4", "mpeg4", false},
    {"aac", "aac", false},          {"opus", "libopus", false},
};

bool name_has(const std::string& name, const char* part) { return name.find(part) != std::string::npos; }

bool prefers_nv12(const std::string& name) {
  return name_has(name, "mediacodec") || name_has(name, "_qsv") || name_has(name, "_amf") || name_has(name, "_mf");
}

template <typename T>
std::vector<T> supported(const AVCodecContext* ctx, const AVCodec* codec, AVCodecConfig what, T end) {
  const void* list = nullptr;
  int n = 0;
  std::vector<T> out;
  if (avcodec_get_supported_config(ctx, codec, what, 0, &list, &n) >= 0 && list) {
    const T* p = static_cast<const T*>(list);
    for (int i = 0; i < n && p[i] != end; ++i) out.push_back(p[i]);
  }
  return out;
}

AVPixelFormat pick_pix_fmt(const AVCodecContext* ctx, const AVCodec* codec) {
  const auto fmts = supported<AVPixelFormat>(ctx, codec, AV_CODEC_CONFIG_PIX_FORMAT, AV_PIX_FMT_NONE);
  if (fmts.empty()) return AV_PIX_FMT_YUV420P;
  const bool nv12_first = prefers_nv12(codec->name);
  const AVPixelFormat order[2] = {nv12_first ? AV_PIX_FMT_NV12 : AV_PIX_FMT_YUV420P, nv12_first ? AV_PIX_FMT_YUV420P : AV_PIX_FMT_NV12};
  for (const auto want : order) {
    if (std::find(fmts.begin(), fmts.end(), want) != fmts.end()) return want;
  }
  throw MediaError(std::string(codec->name) + " does not take 8-bit 4:2:0 pictures");
}

AVSampleFormat pick_sample_fmt(const AVCodecContext* ctx, const AVCodec* codec) {
  const auto fmts = supported<AVSampleFormat>(ctx, codec, AV_CODEC_CONFIG_SAMPLE_FORMAT, AV_SAMPLE_FMT_NONE);
  if (fmts.empty()) return AV_SAMPLE_FMT_FLTP;
  for (const auto want : {AV_SAMPLE_FMT_FLTP, AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_S16, AV_SAMPLE_FMT_S16P}) {
    if (std::find(fmts.begin(), fmts.end(), want) != fmts.end()) return want;
  }
  throw MediaError(std::string(codec->name) + ": no usable sample format");
}

int clampi(double v, int lo, int hi) { return std::clamp(static_cast<int>(std::lround(v)), lo, hi); }

// Rate control and effort for one encoder. Software libraries use their
// constant-quality mode; hardware encoders get the target bitrate (their
// quality modes differ a lot between vendors).
void configure_video(AVCodecContext* ctx, const std::string& name, const ExportSettings& s, bool hw, AVDictionary** opt) {
  const int q = std::clamp(s.quality, 1, 100);
  const int64_t target = s.video_kbps > 0 ? int64_t{s.video_kbps} * 1000 : quality_bitrate(s.video_codec, q, s.width, s.height, s.fps);
  const bool cq = s.video_kbps <= 0;
  const bool fast = s.speed == "fast", best = s.speed == "quality";
  auto set = [&](const char* k, const std::string& v) { av_dict_set(opt, k, v.c_str(), 0); };
  auto vbr = [&] {
    ctx->bit_rate = target;
    ctx->rc_max_rate = target * 3 / 2;
    ctx->rc_buffer_size = static_cast<int>(std::min<int64_t>(target * 2, INT32_MAX));
  };

  if (name == "libopenh264") {
    vbr();
    set("rc_mode", "bitrate");
    set("allow_skip_frames", "0");  // never drop frames to meet the bitrate (frame pacing)
    set("profile", "high");
    set("coder", "cabac");
    ctx->max_b_frames = 0;
  } else if (name == "libkvazaar") {
    std::string params = std::string("preset=") + (fast ? "ultrafast" : best ? "fast" : "superfast");
    if (cq) {
      params += ",qp=" + std::to_string(clampi(47 - q * 0.3, 1, 51));
    } else {
      ctx->bit_rate = target;
    }
    set("kvazaar-params", params);
  } else if (name == "libvpx-vp9") {
    set("deadline", fast ? "realtime" : "good");
    set("cpu-used", fast ? "8" : best ? "2" : "5");
    set("row-mt", "1");
    int tiles = 0;
    while (tiles < 6 && (256 << (tiles + 1)) <= s.width) ++tiles;
    set("tile-columns", std::to_string(tiles));
    set("frame-parallel", "0");
    if (cq) {
      ctx->bit_rate = 0;
      set("crf", std::to_string(clampi(50 - q * 0.33, 4, 63)));
    } else {
      vbr();
    }
  } else if (name == "libsvtav1") {
    set("preset", fast ? "11" : best ? "7" : "10");  // 12–13 are real-time presets; 12 sometimes never finished the stream (seen in CI)
    if (cq) {
      set("crf", std::to_string(clampi(55 - q * 0.33, 1, 63)));
    } else {
      ctx->bit_rate = target;
    }
  } else if (name == "libaom-av1") {
    set("cpu-used", fast ? "8" : best ? "4" : "6");
    set("row-mt", "1");
    if (cq) {
      ctx->bit_rate = 0;
      set("crf", std::to_string(clampi(55 - q * 0.33, 1, 63)));
    } else {
      vbr();
    }
  } else if (name == "mpeg4") {
    if (cq) {
      ctx->flags |= AV_CODEC_FLAG_QSCALE;
      ctx->global_quality = FF_QP2LAMBDA * clampi(31 - q * 0.29, 2, 31);
    } else {
      vbr();
    }
  } else if (name_has(name, "_nvenc")) {
    vbr();
    set("preset", fast ? "p2" : best ? "p6" : "p4");
    set("tune", "hq");
    set("rc", "vbr");
  } else if (name_has(name, "_qsv")) {
    vbr();
    set("preset", fast ? "veryfast" : best ? "slower" : "medium");
  } else if (name_has(name, "_amf")) {
    vbr();
    set("quality", fast ? "speed" : best ? "quality" : "balanced");
    set("rc", "vbr_peak");
  } else if (name_has(name, "_mf")) {
    ctx->bit_rate = target;
    set("rate_control", "u_vbr");
    set("scenario", "archive");
    set("hw_encoding", hw ? "1" : "0");
  } else if (name_has(name, "_mediacodec")) {
    ctx->bit_rate = target;
    set("bitrate_mode", "vbr");
  } else {
    vbr();
  }
}

// One small encode: does this encoder work here (drivers, GPU, MediaCodec)?
std::string try_encoder(const AVCodec* codec, bool hw) {
  try {
    CodecContextPtr ctx(avcodec_alloc_context3(codec));
    if (!ctx) return "out of memory";
    ctx->width = 1280;
    ctx->height = 720;
    ctx->time_base = {1, 30};
    ctx->framerate = {30, 1};
    ctx->gop_size = 30;
    ctx->pix_fmt = pick_pix_fmt(ctx.get(), codec);
    ExportSettings s;
    s.width = 1280;
    s.height = 720;
    s.video_codec = "h264";
    AVDictionary* opt = nullptr;
    configure_video(ctx.get(), codec->name, s, hw, &opt);
    const int r = avcodec_open2(ctx.get(), codec, &opt);
    av_dict_free(&opt);
    if (r < 0) return "cannot start: " + av_error_string(r);
    FramePtr f = make_frame();
    f->format = ctx->pix_fmt;
    f->width = ctx->width;
    f->height = ctx->height;
    check(av_frame_get_buffer(f.get(), 0), "frame");
    PacketPtr pkt = make_packet();
    int packets = 0;
    for (int i = 0; i <= 12; ++i) {
      if (i < 12) {
        check(av_frame_make_writable(f.get()), "frame");
        for (int p = 0; p < 4 && f->data[p]; ++p) {
          const int h = p == 0 ? f->height : f->height / 2;
          std::memset(f->data[p], p == 0 ? 16 + i * 8 : 128, static_cast<size_t>(f->linesize[p]) * h);
        }
        f->pts = i;
      }
      const int sr = avcodec_send_frame(ctx.get(), i < 12 ? f.get() : nullptr);
      if (sr < 0 && sr != AVERROR(EAGAIN)) return "encoding failed: " + av_error_string(sr);
      while (avcodec_receive_packet(ctx.get(), pkt.get()) == 0) {
        ++packets;
        av_packet_unref(pkt.get());
      }
    }
    if (packets == 0) return "produced no output";
    return "";
  } catch (const std::exception& e) {
    return e.what();
  }
}

// ----------------------------------------------------------- pictures

int sws_cs(const AVFrame* f) {
  switch (f->colorspace) {
    case AVCOL_SPC_BT709: return SWS_CS_ITU709;
    case AVCOL_SPC_BT2020_NCL:
    case AVCOL_SPC_BT2020_CL: return SWS_CS_BT2020;
    case AVCOL_SPC_SMPTE170M:
    case AVCOL_SPC_BT470BG: return SWS_CS_ITU601;
    default: return f->height >= 720 ? SWS_CS_ITU709 : SWS_CS_ITU601;
  }
}

bool has_alpha(int fmt) {
  const AVPixFmtDescriptor* d = av_pix_fmt_desc_get(static_cast<AVPixelFormat>(fmt));
  return d && (d->flags & AV_PIX_FMT_FLAG_ALPHA);
}

FramePtr new_picture(AVPixelFormat fmt, int w, int h) {
  FramePtr f = make_frame();
  f->format = fmt;
  f->width = w;
  f->height = h;
  check(av_frame_get_buffer(f.get(), 32), "picture");
  f->color_primaries = AVCOL_PRI_BT709;
  f->color_trc = AVCOL_TRC_BT709;
  f->colorspace = AVCOL_SPC_BT709;
  f->color_range = AVCOL_RANGE_MPEG;
  return f;
}

void fill_black(AVFrame* f) {
  for (int y = 0; y < f->height; ++y) std::memset(f->data[0] + static_cast<size_t>(y) * f->linesize[0], 16, static_cast<size_t>(f->width));
  for (int p = 1; p <= 2; ++p) {
    for (int y = 0; y < f->height / 2; ++y) std::memset(f->data[p] + static_cast<size_t>(y) * f->linesize[p], 128, static_cast<size_t>(f->width / 2));
  }
}

// Rotates one plane clockwise by `rot` degrees into dst (dst size: sh × sw for 90/270).
void rotate_plane(const uint8_t* src, int sls, int sw, int sh, uint8_t* dst, int dls, int rot) {
  for (int y = 0; y < sh; ++y) {
    const uint8_t* row = src + static_cast<size_t>(y) * sls;
    for (int x = 0; x < sw; ++x) {
      int dx, dy;
      if (rot == 90) {
        dx = sh - 1 - y;
        dy = x;
      } else if (rot == 180) {
        dx = sw - 1 - x;
        dy = sh - 1 - y;
      } else {
        dx = y;
        dy = sw - 1 - x;
      }
      dst[static_cast<size_t>(dy) * dls + dx] = row[x];
    }
  }
}

}  // namespace

// ----------------------------------------------------------- public helpers

ExportSettings ExportSettings::parse(const std::string& text) {
  ExportSettings s;
  std::istringstream in(text);
  std::string line;
  while (std::getline(in, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.empty() || line[0] == '#') continue;
    const auto sp = line.find(' ');
    const std::string k = line.substr(0, sp);
    const std::string v = sp == std::string::npos ? "" : line.substr(sp + 1);
    if (k == "path") {
      s.path = v;
    } else if (k == "container") {
      s.container = lower(v);
    } else if (k == "video") {
      s.video_codec = lower(v);
    } else if (k == "encoder") {
      s.encoder = v;
    } else if (k == "size") {
      const auto x = v.find('x');
      if (x == std::string::npos) throw std::invalid_argument("export settings: size must be WxH");
      s.width = static_cast<int>(parse_int(v.substr(0, x), k));
      s.height = static_cast<int>(parse_int(v.substr(x + 1), k));
    } else if (k == "fps") {
      const auto slash = v.find('/');
      const int64_t num = parse_int(v.substr(0, slash), k);
      const int64_t den = slash == std::string::npos ? 1 : parse_int(v.substr(slash + 1), k);
      if (num <= 0 || den <= 0) throw std::invalid_argument("export settings: fps must be positive");
      s.fps = Rational::make(num, den);
    } else if (k == "quality") {
      s.quality = static_cast<int>(parse_int(v, k));
    } else if (k == "bitrate") {
      s.video_kbps = static_cast<int>(parse_int(v, k));
    } else if (k == "speed") {
      s.speed = lower(v);
    } else if (k == "hardware") {
      s.hardware = parse_int(v, k) != 0;
    } else if (k == "keyframes") {
      s.keyframe_seconds = std::stod(v);
    } else if (k == "audio") {
      s.audio_codec = lower(v);
    } else if (k == "audio_bitrate") {
      s.audio_kbps = static_cast<int>(parse_int(v, k));
    } else if (k == "threads") {
      s.threads = static_cast<int>(parse_int(v, k));
    } else {
      throw std::invalid_argument("export settings: unknown key '" + k + "'");
    }
  }
  if (s.path.empty()) throw std::invalid_argument("export settings: no output path");
  if (s.width < 16 || s.height < 16 || s.width > 8192 || s.height > 8192) throw std::invalid_argument("export settings: size out of range");
  s.width &= ~1;
  s.height &= ~1;
  if (s.fps.num <= 0 || static_cast<double>(s.fps.num) / s.fps.den > 240.0) throw std::invalid_argument("export settings: fps out of range");
  const auto& c = s.container;
  if (c != "mp4" && c != "mov" && c != "webm" && c != "mkv") throw std::invalid_argument("export settings: unknown container '" + c + "'");
  const auto& v = s.video_codec;
  if (v != "h264" && v != "hevc" && v != "vp9" && v != "av1" && v != "mpeg4") throw std::invalid_argument("export settings: unknown video codec '" + v + "'");
  if (s.audio_codec != "aac" && s.audio_codec != "opus" && s.audio_codec != "none") throw std::invalid_argument("export settings: unknown audio codec");
  if (c == "webm" && (v == "h264" || v == "hevc" || v == "mpeg4")) throw std::invalid_argument("WebM holds VP9 or AV1 video only");
  if (c == "webm" && s.audio_codec == "aac") throw std::invalid_argument("WebM holds Opus audio, not AAC");
  if ((c == "mp4" || c == "mov") && v == "vp9" && c == "mov") throw std::invalid_argument("MOV cannot hold VP9");
  s.keyframe_seconds = std::clamp(s.keyframe_seconds, 0.2, 20.0);
  s.audio_kbps = std::clamp(s.audio_kbps, 32, 512);
  return s;
}

int64_t quality_bitrate(const std::string& codec, int quality, int width, int height, Rational fps) {
  // Bits per pixel per frame, for H.264 at 30 fps: 0.111 at quality 75
  // (≈12 Mbit/s for 1080p60), doubling every 20 quality points. Higher
  // frame rates need fewer bits per frame; newer codecs need fewer bits.
  const double q = std::clamp(quality, 1, 100);
  const double bpp = 0.111 * std::pow(2.0, (q - 75.0) / 20.0);
  const double f = static_cast<double>(fps.num) / static_cast<double>(fps.den);
  const double factor = codec == "hevc" || codec == "vp9" ? 0.65 : codec == "av1" ? 0.5 : codec == "mpeg4" ? 1.6 : 1.0;
  const double bps = bpp * width * height * 30.0 * std::pow(f / 30.0, 0.8) * factor;
  return std::max<int64_t>(200'000, static_cast<int64_t>(bps));
}

std::vector<EncoderInfo> available_encoders(bool probe) {
  std::vector<EncoderInfo> out;
  for (const auto& c : kCandidates) {
    const AVCodec* codec = avcodec_find_encoder_by_name(c.name);
    if (!codec) continue;
    EncoderInfo e;
    e.codec = c.codec;
    e.name = c.name;
    e.hardware = c.hardware;
    if (probe && c.hardware) {
      e.note = try_encoder(codec, true);
      e.usable = e.note.empty();
      diag::note("encoder test %s: %s", c.name, e.usable ? "ok" : e.note.c_str());
    }
    out.push_back(e);
    // Windows' own (software) H.264/HEVC encoder, licensed with Windows.
    if (std::string(c.name) == "h264_mf" || std::string(c.name) == "hevc_mf") {
      EncoderInfo sw = e;
      sw.hardware = false;
      sw.usable = true;
      sw.note.clear();
      if (probe) {
        sw.note = try_encoder(codec, false);
        sw.usable = sw.note.empty();
      }
      out.push_back(sw);
    }
  }
  // Software after hardware within each codec, keeping the table order.
  std::stable_sort(out.begin(), out.end(), [](const EncoderInfo& a, const EncoderInfo& b) {
    if (a.codec != b.codec) return false;
    return a.hardware && !b.hardware;
  });
  return out;
}

std::string encoders_json(const std::vector<EncoderInfo>& list) {
  JsonWriter j;
  j.begin_array();
  for (const auto& e : list) {
    j.begin_object();
    j.key("codec").value(e.codec);
    j.key("name").value(e.name);
    j.key("hardware").value(e.hardware);
    j.key("usable").value(e.usable);
    j.key("note").value(e.note);
    j.end_object();
  }
  j.end_array();
  return j.str();
}

const char* export_state_name(Exporter::State s) {
  switch (s) {
    case Exporter::State::preparing: return "preparing";
    case Exporter::State::rendering: return "rendering";
    case Exporter::State::finishing: return "finishing";
    case Exporter::State::done: return "done";
    case Exporter::State::failed: return "failed";
    case Exporter::State::cancelled: return "cancelled";
  }
  return "?";
}

// ----------------------------------------------------------- exporter internals

/// A title (RGBA from the app) converted once to Y/U/V/alpha planes.
struct Exporter::Overlay {
  Ticks start = 0, end = 0;
  int x = 0, y = 0, w = 0, h = 0;  // even position and size
  std::vector<uint8_t> Y, A, U, V, A2;
};

struct Exporter::Run {
  // Per attempt (an encoder that fails mid-way is replaced and the export restarts).
  AVFormatContext* fmt = nullptr;
  CodecContextPtr venc;
  CodecContextPtr aenc;
  AVStream* vst = nullptr;
  AVStream* ast = nullptr;
  bool header_written = false;
  std::string part;
  ~Run() {
    if (fmt) {
      if (fmt->pb) avio_closep(&fmt->pb);
      avformat_free_context(fmt);
    }
  }
};

namespace {

std::filesystem::path fs_path(const std::string& utf8) {
#if defined(_WIN32)
  return std::filesystem::u8path(utf8);
#else
  return std::filesystem::path(utf8);
#endif
}

void remove_file(const std::string& path) {
  std::error_code ec;
  std::filesystem::remove(fs_path(path), ec);
}

/// Decodes the picture of one clip for consecutive output times.
struct ClipVideo {
  std::string key;
  Ticks end = 0;
  std::unique_ptr<VideoDecoder> dec;
  VideoFrame cur, nxt;
  bool has_cur = false, has_nxt = false;
  bool failed = false;
  bool still = false;
  int64_t serial = 0;  // changes whenever `cur` changes

  // The frame displayed at source time t (the last one with pts <= t).
  const VideoFrame* at(Ticks t, Ticks slack) {
    if (failed) return nullptr;
    if (still) {
      if (!has_cur) {
        has_cur = dec->next(cur);
        ++serial;
      }
      return has_cur ? &cur : nullptr;
    }
    // Requests only move forward; a long jump (an upper clip covered this
    // one for a while) seeks instead of decoding through.
    const bool far = has_cur && t > cur.pts + 5 * kTicksPerSecond;
    if (!has_cur || far) {
      dec->seek(t, true);
      has_cur = dec->next(cur);
      has_nxt = has_cur && dec->next(nxt);
      ++serial;
    }
    while (has_nxt && nxt.pts <= t + slack) {
      cur = std::move(nxt);
      has_nxt = dec->next(nxt);
      ++serial;
    }
    return has_cur ? &cur : nullptr;
  }
};

}  // namespace

Exporter::Exporter(std::shared_ptr<const TlPlan> plan, ExportSettings settings) : plan_(std::move(plan)), settings_(std::move(settings)) {
  started_ = Clock::now();
  speed_mark_ = started_;
  worker_ = std::thread([this] { work(); });
}

Exporter::~Exporter() {
  cancel();
  if (worker_.joinable()) worker_.join();
}

void Exporter::pause(bool paused) {
  std::lock_guard<std::mutex> lock(mu_);
  if (paused == paused_) return;
  paused_ = paused;
  if (paused) {
    paused_since_ = Clock::now();
  } else {
    paused_ns_ += std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - paused_since_).count();
  }
  cv_.notify_all();
}

void Exporter::cancel() {
  cancel_ = true;
  std::lock_guard<std::mutex> lock(mu_);
  cv_.notify_all();
}

Exporter::State Exporter::state() const {
  std::lock_guard<std::mutex> lock(mu_);
  return state_;
}

bool Exporter::finished() const {
  const State s = state();
  return s == State::done || s == State::failed || s == State::cancelled;
}

void Exporter::wait() {
  std::unique_lock<std::mutex> lock(mu_);
  cv_.wait(lock, [&] { return state_ == State::done || state_ == State::failed || state_ == State::cancelled; });
}

void Exporter::set_state(State s) {
  std::lock_guard<std::mutex> lock(mu_);
  state_ = s;
  if (s == State::done || s == State::failed || s == State::cancelled) finished_at_ = Clock::now();
  cv_.notify_all();
}

bool Exporter::wait_if_paused() {
  std::unique_lock<std::mutex> lock(mu_);
  cv_.wait(lock, [&] { return !paused_ || cancel_.load(); });
  return !cancel_.load();
}

std::string Exporter::status_json() const {
  std::lock_guard<std::mutex> lock(mu_);
  const auto now = (state_ == State::done || state_ == State::failed || state_ == State::cancelled) ? finished_at_ : Clock::now();
  int64_t paused = paused_ns_;
  if (paused_) paused += std::chrono::duration_cast<std::chrono::nanoseconds>(now - paused_since_).count();
  const double elapsed = std::max(0.0, std::chrono::duration<double>(now - started_).count() - paused / 1e9);
  const double avg_fps = elapsed > 0 ? frames_done_ / elapsed : 0;
  const double fps_now = recent_fps_ > 0 ? recent_fps_ : avg_fps;
  const double out_fps = static_cast<double>(settings_.fps.num) / settings_.fps.den;
  const int64_t left = std::max<int64_t>(0, frames_total_ - frames_done_);
  JsonWriter j;
  j.begin_object();
  j.key("state").value(export_state_name(state_));
  j.key("paused").value(paused_);
  j.key("framesDone").value(frames_done_);
  j.key("framesTotal").value(frames_total_);
  j.key("progress").value(frames_total_ > 0 ? static_cast<double>(frames_done_) / frames_total_ : 0.0);
  j.key("elapsedMs").value(static_cast<int64_t>(elapsed * 1000));
  j.key("fps").value(fps_now);
  j.key("speed").value(fps_now / out_fps);
  j.key("etaMs").value(fps_now > 0.01 && state_ == State::rendering ? static_cast<int64_t>(left / fps_now * 1000) : int64_t{-1});
  j.key("bytes").value(bytes_);
  j.key("encoder").value(encoder_name_);
  j.key("hardware").value(encoder_hw_);
  j.key("audioEncoder").value(audio_encoder_);
  j.key("restarts").value(restarts_);
  j.key("decodeErrors").value(decode_errors_);
  j.key("error").value(error_);
  j.key("warnings").begin_array();
  for (const auto& w : warnings_) j.value(w);
  j.end_array();
  j.end_object();
  return j.str();
}

void Exporter::work() {
  const ExportSettings& s = settings_;
  try {
    // Encoder order: the one asked for, else hardware (when allowed) then software.
    // Encoder order: the list asked for ("encoder a,b,c": the app passes the
    // ones that passed its test, hardware first), else every one in the
    // build, hardware (when allowed) before software.
    std::vector<EncoderInfo> order;
    const auto all = available_encoders(false);
    if (!s.encoder.empty()) {
      // Each entry is "name", "name/hw" or "name/sw" (Windows' Media
      // Foundation encoders exist in a hardware and a software variant).
      std::istringstream names(s.encoder);
      std::string entry;
      while (std::getline(names, entry, ',')) {
        const auto slash = entry.find('/');
        const std::string name = entry.substr(0, slash);
        const std::string variant = slash == std::string::npos ? "" : entry.substr(slash + 1);
        for (const auto& e : all) {
          const bool hw_variant = e.hardware;
          if (e.name != name || e.codec != s.video_codec || (hw_variant && !s.hardware)) continue;
          if ((variant == "hw" && !hw_variant) || (variant == "sw" && hw_variant)) continue;
          if (std::none_of(order.begin(), order.end(), [&](const EncoderInfo& o) { return o.name == e.name && o.hardware == e.hardware; })) {
            order.push_back(e);
          }
        }
      }
    } else {
      for (const auto& e : all) {
        if (e.codec == s.video_codec && (!e.hardware || s.hardware)) order.push_back(e);
      }
    }
    if (order.empty()) {
      throw MediaError(s.encoder.empty() ? "no " + s.video_codec + " encoder in this build" : s.encoder + " is not available");
    }
    std::string last_error;
    for (size_t i = 0; i < order.size(); ++i) {
      Run run;
      try {
        {
          std::lock_guard<std::mutex> lock(mu_);
          encoder_name_ = order[i].name;
          encoder_hw_ = order[i].hardware;
          frames_done_ = 0;
          bytes_ = 0;
        }
        run_once(order[i], run);
        set_state(State::done);
        diag::note("export done: %s %dx%d, %lld frames", order[i].name.c_str(), s.width, s.height, static_cast<long long>(frames_total_));
        return;
      } catch (const Cancelled&) {
        throw;
      } catch (const std::exception& e) {
        last_error = e.what();
        if (run.fmt && run.fmt->pb) avio_closep(&run.fmt->pb);
        if (!run.part.empty()) remove_file(run.part);
        const bool more = i + 1 < order.size();
        diag::note("export with %s failed: %s%s", order[i].name.c_str(), e.what(), more ? " (trying the next encoder)" : "");
        // Any encoder that fails (a GPU or a Windows codec pack that is not
        // there) hands over to the next one; the export restarts cleanly.
        if (!more) throw;
        auto label = [](const EncoderInfo& x) { return x.name + (x.hardware ? " (hardware)" : " (software)"); };
        std::lock_guard<std::mutex> lock(mu_);
        warnings_.push_back(label(order[i]) + " failed (" + last_error + "); restarted with " + label(order[i + 1]));
        ++restarts_;
      }
    }
    throw MediaError(last_error);
  } catch (const Cancelled&) {
    remove_file(s.path + ".part");
    set_state(State::cancelled);
    diag::note("export cancelled");
  } catch (const std::exception& e) {
    remove_file(s.path + ".part");
    {
      std::lock_guard<std::mutex> lock(mu_);
      error_ = e.what();
    }
    set_state(State::failed);
    diag::note("export failed: %s", e.what());
  }
}

void Exporter::run_once(const EncoderInfo& enc_info, Run& run) {
  const ExportSettings& s = settings_;
  const TlPlan& plan = *plan_;
  set_state(State::preparing);
  const int W = s.width, H = s.height;
  const Ticks duration = plan.duration;
  if (duration <= 0) throw MediaError("the timeline is empty");
  // Output frame n is shown at n / fps.
  const Rational frame_dur = Rational::make(s.fps.den, s.fps.num);
  auto frame_time = [&](int64_t n) { return rescale(n, frame_dur, Rational{1, kTicksPerSecond}, Rounding::Nearest); };
  const int64_t total = rescale(duration, Rational{1, kTicksPerSecond}, frame_dur, Rounding::Up);
  const int64_t total_samples = (duration + kTicksPerSample - 1) / kTicksPerSample;
  {
    std::lock_guard<std::mutex> lock(mu_);
    frames_total_ = total;
  }

  // ---- titles
  std::vector<Overlay> overlays;
  for (const auto& o : plan.overlays) {
    std::ifstream in(fs_path(o.path), std::ios::binary);
    std::vector<uint8_t> rgba(static_cast<size_t>(o.w) * o.h * 4);
    if (!in || !in.read(reinterpret_cast<char*>(rgba.data()), static_cast<std::streamsize>(rgba.size()))) {
      std::lock_guard<std::mutex> lock(mu_);
      warnings_.push_back("a title picture could not be read; it is left out");
      continue;
    }
    Overlay ov;
    ov.start = o.start;
    ov.end = o.end();
    ov.x = o.x & ~1;
    ov.y = o.y & ~1;
    ov.w = (o.w + 1) & ~1;
    ov.h = (o.h + 1) & ~1;
    ov.Y.assign(static_cast<size_t>(ov.w) * ov.h, 16);
    ov.A.assign(static_cast<size_t>(ov.w) * ov.h, 0);
    const int cw = ov.w / 2, ch = ov.h / 2;
    ov.U.assign(static_cast<size_t>(cw) * ch, 128);
    ov.V.assign(static_cast<size_t>(cw) * ch, 128);
    ov.A2.assign(static_cast<size_t>(cw) * ch, 0);
    for (int y = 0; y < o.h; ++y) {
      for (int x = 0; x < o.w; ++x) {
        const uint8_t* p = &rgba[(static_cast<size_t>(y) * o.w + x) * 4];
        const double r = p[0], g = p[1], b = p[2];
        ov.Y[static_cast<size_t>(y) * ov.w + x] = static_cast<uint8_t>(std::lround(16 + (0.2126 * r + 0.7152 * g + 0.0722 * b) * 219.0 / 255.0));
        ov.A[static_cast<size_t>(y) * ov.w + x] = p[3];
      }
    }
    for (int y = 0; y < ch; ++y) {
      for (int x = 0; x < cw; ++x) {
        double sa = 0, su = 0, sv = 0;
        for (int dy = 0; dy < 2; ++dy) {
          for (int dx = 0; dx < 2; ++dx) {
            const int px = 2 * x + dx, py = 2 * y + dy;
            if (px >= o.w || py >= o.h) continue;
            const uint8_t* p = &rgba[(static_cast<size_t>(py) * o.w + px) * 4];
            const double a = p[3], r = p[0], g = p[1], b = p[2];
            sa += a;
            su += a * (-0.1146 * r - 0.3854 * g + 0.5 * b);
            sv += a * (0.5 * r - 0.4542 * g - 0.0458 * b);
          }
        }
        const size_t i = static_cast<size_t>(y) * cw + x;
        ov.A2[i] = static_cast<uint8_t>(std::lround(sa / 4));
        if (sa > 0) {
          ov.U[i] = static_cast<uint8_t>(std::clamp<long>(std::lround(128 + su / sa * 224.0 / 255.0), 0, 255));
          ov.V[i] = static_cast<uint8_t>(std::clamp<long>(std::lround(128 + sv / sa * 224.0 / 255.0), 0, 255));
        }
      }
    }
    overlays.push_back(std::move(ov));
  }

  // ---- output file and encoders
  run.part = s.path + ".part";
  const char* muxer = s.container == "mkv" ? "matroska" : s.container.c_str();
  check(avformat_alloc_output_context2(&run.fmt, nullptr, muxer, nullptr), "output format");
  if (!run.fmt) throw MediaError("cannot create the output file format");

  const AVCodec* vcodec = avcodec_find_encoder_by_name(enc_info.name.c_str());
  if (!vcodec) throw MediaError(enc_info.name + " is not in this build");
  run.venc.reset(avcodec_alloc_context3(vcodec));
  AVCodecContext* venc = run.venc.get();
  venc->width = W;
  venc->height = H;
  venc->time_base = AVRational{static_cast<int>(s.fps.den), static_cast<int>(s.fps.num)};
  venc->framerate = AVRational{static_cast<int>(s.fps.num), static_cast<int>(s.fps.den)};
  venc->sample_aspect_ratio = AVRational{1, 1};
  venc->gop_size = std::max(1, static_cast<int>(std::lround(s.keyframe_seconds * s.fps.num / s.fps.den)));
  venc->pix_fmt = pick_pix_fmt(venc, vcodec);
  venc->color_primaries = AVCOL_PRI_BT709;
  venc->color_trc = AVCOL_TRC_BT709;
  venc->colorspace = AVCOL_SPC_BT709;
  venc->color_range = AVCOL_RANGE_MPEG;
  venc->thread_count = s.threads;
  // MediaCodec: FFmpeg makes the global header by encoding a dummy frame,
  // ending the stream and flushing; Android's encoders then produce nothing
  // more (seen on the emulators). The parameter sets come with the first
  // packet instead, and the MP4/MKV muxers take them from there.
  if ((run.fmt->oformat->flags & AVFMT_GLOBALHEADER) && !name_has(enc_info.name, "_mediacodec")) venc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
  {
    AVDictionary* opt = nullptr;
    configure_video(venc, enc_info.name, s, enc_info.hardware, &opt);
    const int r = avcodec_open2(venc, vcodec, &opt);
    av_dict_free(&opt);
    check(r, (enc_info.name + " could not start").c_str());
  }
  run.vst = avformat_new_stream(run.fmt, nullptr);
  if (!run.vst) throw MediaError("cannot add the video stream");
  check(avcodec_parameters_from_context(run.vst->codecpar, venc), "video stream");
  run.vst->time_base = venc->time_base;
  run.vst->avg_frame_rate = venc->framerate;
  run.vst->r_frame_rate = venc->framerate;

  std::vector<float> mixbuf;
  int audio_frame = 1024;
  if (s.audio_codec != "none") {
    const char* aname = s.audio_codec == "opus" ? "libopus" : "aac";
    const AVCodec* acodec = avcodec_find_encoder_by_name(aname);
    if (!acodec) throw MediaError(std::string(s.audio_codec == "opus" ? "Opus" : "AAC") + " audio encoding is not in this build");
    run.aenc.reset(avcodec_alloc_context3(acodec));
    AVCodecContext* aenc = run.aenc.get();
    aenc->sample_rate = kMixRate;
    av_channel_layout_default(&aenc->ch_layout, kMixChannels);
    aenc->sample_fmt = pick_sample_fmt(aenc, acodec);
    aenc->bit_rate = int64_t{s.audio_kbps} * 1000;
    aenc->time_base = AVRational{1, kMixRate};
    if (run.fmt->oformat->flags & AVFMT_GLOBALHEADER) aenc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    check(avcodec_open2(aenc, acodec, nullptr), "audio encoder");
    audio_frame = aenc->frame_size > 0 ? aenc->frame_size : 1024;
    run.ast = avformat_new_stream(run.fmt, nullptr);
    if (!run.ast) throw MediaError("cannot add the audio stream");
    check(avcodec_parameters_from_context(run.ast->codecpar, aenc), "audio stream");
    run.ast->time_base = aenc->time_base;
    std::lock_guard<std::mutex> lock(mu_);
    audio_encoder_ = aname;
  }

  check(avio_open(&run.fmt->pb, run.part.c_str(), AVIO_FLAG_WRITE), "cannot write the output file");
  av_freep(&run.fmt->url);
  run.fmt->url = av_strdup(run.part.c_str());  // "faststart" reopens the file by name
  {
    AVDictionary* mopt = nullptr;
    if (s.container == "mp4" || s.container == "mov") av_dict_set(&mopt, "movflags", "+faststart", 0);
    const int r = avformat_write_header(run.fmt, &mopt);
    av_dict_free(&mopt);
    check(r, "cannot write the output file");
    run.header_written = true;
  }

  PacketPtr pkt = make_packet();
  // Packets ready now; returns how many were written. Hardware encoders
  // (MediaCodec, GPUs) work asynchronously: "not yet" is normal.
  auto drain = [&](AVCodecContext* ctx, AVStream* st) {
    int written = 0;
    for (;;) {
      const int r = avcodec_receive_packet(ctx, pkt.get());
      if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) return written;
      check(r, ctx == venc ? "video encoding" : "audio encoding");
      if (pkt->size <= 0) {  // nothing to store (some encoders signal the end this way)
        av_packet_unref(pkt.get());
        continue;
      }
      av_packet_rescale_ts(pkt.get(), ctx->time_base, st->time_base);
      pkt->stream_index = st->index;
      check(av_interleaved_write_frame(run.fmt, pkt.get()), "writing the output file");
      ++written;
    }
  };
  // An encoder that neither takes input nor gives output for this long has
  // stopped working (a stuck hardware encoder): the next encoder takes over.
  constexpr auto kStuck = std::chrono::seconds(20);
  auto wait_a_moment = [&](Clock::time_point since, AVCodecContext* ctx) {
    if (cancel_) throw Cancelled{};
    if (Clock::now() - since > kStuck) throw MediaError(std::string(ctx->codec->name) + " stopped responding");
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  };
  auto send = [&](AVCodecContext* ctx, AVStream* st, AVFrame* f) {
    const auto since = Clock::now();
    for (;;) {
      const int r = avcodec_send_frame(ctx, f);
      if (r == AVERROR(EAGAIN)) {
        if (drain(ctx, st) == 0) wait_a_moment(since, ctx);
        continue;
      }
      if (r == AVERROR_EOF && !f) break;  // already flushed
      check(r, ctx == venc ? "video encoding" : "audio encoding");
      break;
    }
    drain(ctx, st);
  };
  // End of stream: every packet the encoder still holds, until it says EOF.
  // Software encoders hand everything over synchronously after the flush
  // (asking SVT-AV1 again after that can block for ever); asynchronous
  // hardware encoders may still say "not yet" and are waited for.
  auto finish_encoder = [&](AVCodecContext* ctx, AVStream* st, bool asynchronous) {
    send(ctx, st, nullptr);
    if (!asynchronous) return;
    auto since = Clock::now();
    for (;;) {
      const int r = avcodec_receive_packet(ctx, pkt.get());
      if (r == AVERROR_EOF) return;
      if (r == AVERROR(EAGAIN)) {
        wait_a_moment(since, ctx);
        continue;
      }
      check(r, ctx == venc ? "video encoding" : "audio encoding");
      since = Clock::now();
      if (pkt->size <= 0) {
        av_packet_unref(pkt.get());
        continue;
      }
      av_packet_rescale_ts(pkt.get(), ctx->time_base, st->time_base);
      pkt->stream_index = st->index;
      check(av_interleaved_write_frame(run.fmt, pkt.get()), "writing the output file");
    }
  };

  // ---- audio
  Mixer mixer;
  int64_t audio_pos = 0;
  FramePtr aframe;
  // Whole encoder frames up to `until`; with final=true everything to the end
  // (the last frame may be shorter).
  auto encode_audio_until = [&](int64_t until, bool final) {
    if (!run.aenc) return;
    AVCodecContext* aenc = run.aenc.get();
    for (;;) {
      const int64_t left = total_samples - audio_pos;
      if (left <= 0) break;
      const int n = static_cast<int>(std::min<int64_t>(audio_frame, left));
      if (!final && audio_pos + n > until) break;
      mixbuf.resize(static_cast<size_t>(n) * kMixChannels);
      mixer.render(plan, audio_pos, static_cast<size_t>(n), mixbuf.data(), nullptr, nullptr);
      aframe = make_frame();
      aframe->format = aenc->sample_fmt;
      aframe->nb_samples = n;
      aframe->sample_rate = kMixRate;
      check(av_channel_layout_copy(&aframe->ch_layout, &aenc->ch_layout), "audio frame");
      check(av_frame_get_buffer(aframe.get(), 0), "audio frame");
      const float* in = mixbuf.data();
      switch (aenc->sample_fmt) {
        case AV_SAMPLE_FMT_FLTP:
          for (int c = 0; c < kMixChannels; ++c) {
            auto* d = reinterpret_cast<float*>(aframe->data[c]);
            for (int i = 0; i < n; ++i) d[i] = in[i * kMixChannels + c];
          }
          break;
        case AV_SAMPLE_FMT_FLT:
          std::memcpy(aframe->data[0], in, static_cast<size_t>(n) * kMixChannels * sizeof(float));
          break;
        case AV_SAMPLE_FMT_S16: {
          auto* d = reinterpret_cast<int16_t*>(aframe->data[0]);
          for (int i = 0; i < n * kMixChannels; ++i) d[i] = static_cast<int16_t>(std::lround(std::clamp(in[i], -1.0f, 1.0f) * 32767.0f));
          break;
        }
        default:  // S16P
          for (int c = 0; c < kMixChannels; ++c) {
            auto* d = reinterpret_cast<int16_t*>(aframe->data[c]);
            for (int i = 0; i < n; ++i) d[i] = static_cast<int16_t>(std::lround(std::clamp(in[i * kMixChannels + c], -1.0f, 1.0f) * 32767.0f));
          }
      }
      aframe->pts = audio_pos;
      send(aenc, run.ast, aframe.get());
      audio_pos += n;
    }
  };

  // ---- pictures
  const auto segments = picture_segments(plan);
  std::map<std::string, ClipVideo> videos;
  DecodeOptions dopts;
  dopts.native = true;
  dopts.prefer_hardware = plan.hardware;
  const Ticks slack = kTicksPerSecond / 1000;
  SwsContext* sws = nullptr;
  SwsContext* sws_alpha = nullptr;
  FramePtr tmp;           // scaled, before rotation
  std::vector<uint8_t> premult;  // stills with transparency, premultiplied on black
  FramePtr canvas;        // last composed picture
  std::string canvas_key;
  FramePtr nv12;
  SwsContext* to_nv12 = nullptr;
  struct SwsGuard {
    SwsContext** p[3];
    ~SwsGuard() {
      for (auto** q : p) {
        if (*q) sws_freeContext(*q);
      }
    }
  } sws_guard{{&sws, &sws_alpha, &to_nv12}};
  size_t seg_i = 0;
  int64_t decode_errors_seen = 0;

  set_state(State::rendering);
  {
    std::lock_guard<std::mutex> lock(mu_);
    speed_mark_ = Clock::now();
    speed_mark_frames_ = 0;
  }

  for (int64_t n = 0; n < total; ++n) {
    if (cancel_ || !wait_if_paused()) throw Cancelled{};
    const Ticks t = frame_time(n);
    while (seg_i + 1 < segments.size() && segments[seg_i].end <= t) ++seg_i;
    const TlClip* clip = (seg_i < segments.size() && segments[seg_i].start <= t && t < segments[seg_i].end) ? segments[seg_i].clip : nullptr;

    // Decoders for clips that are over are closed.
    for (auto it = videos.begin(); it != videos.end();) {
      if (it->second.end <= t) {
        decode_errors_seen += it->second.dec ? it->second.dec->decode_errors() : 0;
        it = videos.erase(it);
      } else {
        ++it;
      }
    }

    const VideoFrame* pic = nullptr;
    std::string key;
    if (clip) {
      const std::string ck = clip->id + '\n' + clip->uri;
      auto it = videos.find(ck);
      if (it == videos.end()) {
        ClipVideo cv;
        cv.key = ck;
        cv.end = clip->end();
        cv.still = clip->still;
        try {
          cv.dec = std::make_unique<VideoDecoder>(Source::parse(clip->uri), dopts);
          cv.still = cv.still || cv.dec->still_image();
        } catch (const std::exception& e) {
          cv.failed = true;
          std::lock_guard<std::mutex> lock(mu_);
          warnings_.push_back("clip " + clip->id + ": the video could not be read (" + std::string(e.what()) + "); it is exported as black");
        }
        it = videos.emplace(ck, std::move(cv)).first;
      }
      try {
        pic = it->second.at(clip->src_in + (t - clip->start), slack);
      } catch (const std::exception& e) {
        it->second.failed = true;
        std::lock_guard<std::mutex> lock(mu_);
        warnings_.push_back("clip " + clip->id + ": decoding stopped (" + std::string(e.what()) + "); the rest of the clip is black");
      }
      if (pic && pic->native) key = ck + '\n' + std::to_string(it->second.serial);
    }
    std::string ov_key;
    for (size_t i = 0; i < overlays.size(); ++i) {
      if (overlays[i].start <= t && t < overlays[i].end) ov_key += std::to_string(i) + ',';
    }
    key += '|' + ov_key;

    if (!canvas || key != canvas_key) {
      FramePtr c = new_picture(AV_PIX_FMT_YUV420P, W, H);
      fill_black(c.get());
      if (pic && pic->native) {
        const AVFrame* f = pic->native.get();
        // Fit inside the frame (letterbox), even sizes and positions.
        const double scale = std::min(static_cast<double>(W) / pic->width, static_cast<double>(H) / pic->height);
        const int fw = std::clamp(static_cast<int>(std::lround(pic->width * scale)) & ~1, 2, W);
        const int fh = std::clamp(static_cast<int>(std::lround(pic->height * scale)) & ~1, 2, H);
        const int x0 = ((W - fw) / 2) & ~1, y0 = ((H - fh) / 2) & ~1;
        const bool side = pic->rotation == 90 || pic->rotation == 270;
        const int sw_w = side ? fh : fw, sw_h = side ? fw : fh;  // size before rotation

        const uint8_t* const* src_data = f->data;
        const int* src_ls = f->linesize;
        AVPixelFormat src_fmt = static_cast<AVPixelFormat>(f->format);
        uint8_t* pm_data[4] = {nullptr, nullptr, nullptr, nullptr};
        int pm_ls[4] = {0, 0, 0, 0};
        if (has_alpha(f->format)) {
          // Transparent photo: composite on black first (as the monitor shows it).
          sws_alpha = sws_getCachedContext(sws_alpha, f->width, f->height, src_fmt, f->width, f->height, AV_PIX_FMT_RGBA, SWS_POINT, nullptr,
                                           nullptr, nullptr);
          if (!sws_alpha) throw MediaError("cannot convert the picture");
          premult.resize(static_cast<size_t>(f->width) * f->height * 4);
          pm_data[0] = premult.data();
          pm_ls[0] = f->width * 4;
          sws_scale(sws_alpha, f->data, f->linesize, 0, f->height, pm_data, pm_ls);
          for (size_t i = 0; i < premult.size(); i += 4) {
            const unsigned a = premult[i + 3];
            for (int k = 0; k < 3; ++k) premult[i + k] = static_cast<uint8_t>((premult[i + k] * a + 127) / 255);
            premult[i + 3] = 255;
          }
          src_data = pm_data;
          src_ls = pm_ls;
          src_fmt = AV_PIX_FMT_RGBA;
        }
        const bool same = sw_w == f->width && sw_h == f->height;
        sws = sws_getCachedContext(sws, f->width, f->height, src_fmt, sw_w, sw_h, AV_PIX_FMT_YUV420P, same ? SWS_POINT : SWS_BICUBIC, nullptr,
                                   nullptr, nullptr);
        if (!sws) throw MediaError("cannot scale the picture");
        sws_setColorspaceDetails(sws, sws_getCoefficients(sws_cs(f)), f->color_range == AVCOL_RANGE_JPEG ? 1 : 0, sws_getCoefficients(SWS_CS_ITU709),
                                 0, 0, 1 << 16, 1 << 16);
        if (pic->rotation == 0) {
          uint8_t* dst[4] = {c->data[0] + static_cast<size_t>(y0) * c->linesize[0] + x0,
                             c->data[1] + static_cast<size_t>(y0 / 2) * c->linesize[1] + x0 / 2,
                             c->data[2] + static_cast<size_t>(y0 / 2) * c->linesize[2] + x0 / 2, nullptr};
          sws_scale(sws, src_data, src_ls, 0, f->height, dst, c->linesize);
        } else {
          if (!tmp || tmp->width != sw_w || tmp->height != sw_h) tmp = new_picture(AV_PIX_FMT_YUV420P, sw_w, sw_h);
          sws_scale(sws, src_data, src_ls, 0, f->height, tmp->data, tmp->linesize);
          for (int p = 0; p < 3; ++p) {
            const int div = p == 0 ? 1 : 2;
            rotate_plane(tmp->data[p], tmp->linesize[p], sw_w / div, sw_h / div,
                         c->data[p] + static_cast<size_t>(y0 / div) * c->linesize[p] + x0 / div, c->linesize[p], pic->rotation);
          }
        }
      }
      // Titles.
      for (const auto& ov : overlays) {
        if (!(ov.start <= t && t < ov.end)) continue;
        for (int y = 0; y < ov.h; ++y) {
          const int cy = ov.y + y;
          if (cy < 0 || cy >= H) continue;
          uint8_t* row = c->data[0] + static_cast<size_t>(cy) * c->linesize[0];
          for (int x = 0; x < ov.w; ++x) {
            const int cx = ov.x + x;
            if (cx < 0 || cx >= W) continue;
            const unsigned a = ov.A[static_cast<size_t>(y) * ov.w + x];
            if (!a) continue;
            const int src = ov.Y[static_cast<size_t>(y) * ov.w + x];
            row[cx] = static_cast<uint8_t>((src * a + row[cx] * (255 - a) + 127) / 255);
          }
        }
        for (int y = 0; y < ov.h / 2; ++y) {
          const int cy = ov.y / 2 + y;
          if (cy < 0 || cy >= H / 2) continue;
          uint8_t* ru = c->data[1] + static_cast<size_t>(cy) * c->linesize[1];
          uint8_t* rv = c->data[2] + static_cast<size_t>(cy) * c->linesize[2];
          for (int x = 0; x < ov.w / 2; ++x) {
            const int cx = ov.x / 2 + x;
            if (cx < 0 || cx >= W / 2) continue;
            const size_t i = static_cast<size_t>(y) * (ov.w / 2) + x;
            const unsigned a = ov.A2[i];
            if (!a) continue;
            ru[cx] = static_cast<uint8_t>((ov.U[i] * a + ru[cx] * (255 - a) + 127) / 255);
            rv[cx] = static_cast<uint8_t>((ov.V[i] * a + rv[cx] * (255 - a) + 127) / 255);
          }
        }
      }
      canvas = std::move(c);
      canvas_key = key;
    }

    // The encoder gets its own reference (repeated pictures share memory).
    FramePtr out = make_frame();
    if (venc->pix_fmt == AV_PIX_FMT_NV12) {
      nv12 = new_picture(AV_PIX_FMT_NV12, W, H);
      to_nv12 = sws_getCachedContext(to_nv12, W, H, AV_PIX_FMT_YUV420P, W, H, AV_PIX_FMT_NV12, SWS_POINT, nullptr, nullptr, nullptr);
      if (!to_nv12) throw MediaError("cannot convert to NV12");
      sws_scale(to_nv12, canvas->data, canvas->linesize, 0, H, nv12->data, nv12->linesize);
      check(av_frame_ref(out.get(), nv12.get()), "picture");
    } else {
      check(av_frame_ref(out.get(), canvas.get()), "picture");
    }
    out->pts = n;
    out->duration = 1;
    out->pict_type = AV_PICTURE_TYPE_NONE;
    send(venc, run.vst, out.get());
    // Sound up to the end of this frame.
    encode_audio_until(ticks_to_samples(frame_time(n + 1)), false);

    std::lock_guard<std::mutex> lock(mu_);
    frames_done_ = n + 1;
    bytes_ = avio_tell(run.fmt->pb);
    const auto now = Clock::now();
    const double dt = std::chrono::duration<double>(now - speed_mark_).count();
    if (dt >= 1.5 && !paused_) {
      recent_fps_ = (frames_done_ - speed_mark_frames_) / dt;
      speed_mark_ = now;
      speed_mark_frames_ = frames_done_;
    }
  }

  // ---- finish: flush encoders, write the index, rename.
  set_state(State::finishing);
  encode_audio_until(total_samples, true);
  if (run.aenc) finish_encoder(run.aenc.get(), run.ast, false);
  finish_encoder(venc, run.vst, enc_info.hardware);
  for (auto& v : videos) decode_errors_seen += v.second.dec ? v.second.dec->decode_errors() : 0;
  check(av_write_trailer(run.fmt), "finishing the output file");
  {
    std::lock_guard<std::mutex> lock(mu_);
    bytes_ = avio_tell(run.fmt->pb);
    decode_errors_ = decode_errors_seen;
    if (mixer.clipped_samples() > 0) {
      warnings_.push_back("the mix was louder than full scale in places (" + std::to_string(mixer.clipped_samples()) +
                          " samples limited); lower the master or track volume");
    }
    if (!mixer.last_error().empty()) warnings_.push_back("audio: " + mixer.last_error());
  }
  check(avio_closep(&run.fmt->pb), "closing the output file");
  std::error_code ec;
  std::filesystem::remove(fs_path(s.path), ec);
  std::filesystem::rename(fs_path(run.part), fs_path(s.path), ec);
  if (ec) throw MediaError("cannot rename the finished file: " + ec.message());
  run.part.clear();
  const auto size = std::filesystem::file_size(fs_path(s.path), ec);
  if (!ec) {
    std::lock_guard<std::mutex> lock(mu_);
    bytes_ = static_cast<int64_t>(size);
  }
}

}  // namespace cutlab::media
