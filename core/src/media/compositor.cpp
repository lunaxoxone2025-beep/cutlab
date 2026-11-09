// Timeline picture composition. See compositor.hpp.
#include "compositor.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>

#include "../diag/diag.hpp"

namespace cutlab::media {

// ------------------------------------------------------------ what shows

bool Composition::styled() const { return b != nullptr || dip < 1 || (a && a->styled()); }

namespace {

void set_transition(const TlClip& a, const TlClip& b, Ticks t, Composition& k) {
  const Ticks T = b.start, L = b.tin.left, R = b.tin.right;
  k.kind = b.tin.kind;
  k.dir = b.tin.dir;
  if (transition_overlaps(b.tin.kind)) {
    k.a = &a;
    k.a_src = a.src_in + (t - a.start);
    k.b = &b;
    k.b_src = std::max<Ticks>(0, b.src_in + (t - b.start));
    k.progress = std::clamp(static_cast<double>(t - (T - L)) / static_cast<double>(L + R), 0.0, 1.0);
    return;
  }
  k.dip_toward = b.tin.kind == TransitionKind::dip_white ? 255 : 0;
  if (t < T) {
    k.a = &a;
    k.a_src = a.src_in + (t - a.start);
    k.dip = L > 0 ? std::clamp(static_cast<double>(T - t) / static_cast<double>(L), 0.0, 1.0) : 1.0;
  } else {
    k.a = &b;
    k.a_src = b.src_in + (t - b.start);
    k.dip = R > 0 ? std::clamp(static_cast<double>(t - T) / static_cast<double>(R), 0.0, 1.0) : 1.0;
  }
}

}  // namespace

Composition compose_at(const TlPlan& plan, Ticks t) {
  Composition k;
  for (auto tr = plan.tracks.rbegin(); tr != plan.tracks.rend(); ++tr) {
    if (tr->hidden || tr->kind == TlKind::audio) continue;
    const auto& clips = tr->clips;
    // Last clip starting at or before t.
    auto it = std::upper_bound(clips.begin(), clips.end(), t, [](Ticks v, const TlClip& c) { return v < c.start; });
    if (it == clips.begin()) continue;
    const size_t i = static_cast<size_t>(std::distance(clips.begin(), it)) - 1;
    const TlClip& c = clips[i];
    if (t >= c.end()) continue;
    k.a = &c;
    k.a_src = c.src_in + (t - c.start);
    if (c.tin.on && i > 0 && t < c.start + c.tin.right) {
      set_transition(clips[i - 1], c, t, k);
    } else if (i + 1 < clips.size() && clips[i + 1].tin.on && clips[i + 1].start == c.end() && t >= c.end() - clips[i + 1].tin.left) {
      set_transition(c, clips[i + 1], t, k);
    }
    return k;
  }
  return k;
}

double video_fade_level(const TlClip& c, Ticks t) {
  if (c.vfade_in <= 0 && c.vfade_out <= 0) return 1;
  const Ticks k = std::clamp<Ticks>(t - c.start, 0, c.duration);
  double level = 1;
  if (c.vfade_in > 0 && k < c.vfade_in) level = static_cast<double>(k) / static_cast<double>(c.vfade_in);
  if (c.vfade_out > 0 && k > c.duration - c.vfade_out) level = std::min(level, static_cast<double>(c.duration - k) / static_cast<double>(c.vfade_out));
  return std::clamp(level, 0.0, 1.0);
}

void fit_rect(int pw, int ph, int W, int H, int* x, int* y, int* w, int* h) {
  if (pw <= 0 || ph <= 0) {
    *x = *y = 0;
    *w = W;
    *h = H;
    return;
  }
  const double scale = std::min(static_cast<double>(W) / pw, static_cast<double>(H) / ph);
  *w = std::clamp(static_cast<int>(std::lround(pw * scale)) & ~1, 2, W);
  *h = std::clamp(static_cast<int>(std::lround(ph * scale)) & ~1, 2, H);
  *x = ((W - *w) / 2) & ~1;
  *y = ((H - *h) / 2) & ~1;
}

// ------------------------------------------------------------ frame pool

const VideoFrame* FramePool::frame(const TlClip& c, Ticks src, int64_t* serial) {
  const std::string key = c.id + '\n' + c.uri;
  auto it = clips_.find(key);
  if (it == clips_.end()) {
    Clip cl;
    cl.begin = c.start - c.lead;
    cl.end = c.end() + c.tail;
    cl.still = c.still;
    try {
      DecodeOptions o = opts_;
      o.prefer_hardware = o.prefer_hardware && !c.still;
      cl.dec = std::make_unique<VideoDecoder>(Source::parse(c.uri), o);
      cl.still = cl.still || cl.dec->still_image();
    } catch (const std::exception& e) {
      cl.failed = true;
      warnings_.push_back("clip " + c.id + ": the video could not be read (" + std::string(e.what()) + "); it is shown as black");
    }
    it = clips_.emplace(key, std::move(cl)).first;
  }
  Clip& cl = it->second;
  cl.begin = c.start - c.lead;  // (the plan may have moved the clip)
  cl.end = c.end() + c.tail;
  if (serial) *serial = cl.serial;
  if (cl.failed) return nullptr;
  try {
    if (cl.still) {
      if (!cl.has_cur) {
        cl.has_cur = cl.dec->next(cl.cur);
        ++cl.serial;
      }
    } else {
      const Ticks slack = kTicksPerSecond / 1000;
      // Requests normally move forward one frame at a time; a jump back (a
      // seek in the preview) or far ahead positions the decoder again.
      const bool jump = cl.has_cur && (src + slack < cl.cur.pts || src > cl.cur.pts + 5 * kTicksPerSecond);
      if (!cl.has_cur || jump) {
        cl.dec->seek(src, true);
        cl.has_cur = cl.dec->next(cl.cur);
        cl.has_nxt = cl.has_cur && cl.dec->next(cl.nxt);
        ++cl.serial;
      }
      while (cl.has_nxt && cl.nxt.pts <= src + slack) {
        cl.cur = std::move(cl.nxt);
        cl.has_nxt = cl.dec->next(cl.nxt);
        ++cl.serial;
      }
    }
    last_name_ = cl.dec->decoder_name();
    last_hw_ = cl.dec->hardware();
  } catch (const std::exception& e) {
    cl.failed = true;
    warnings_.push_back("clip " + c.id + ": decoding stopped (" + std::string(e.what()) + "); the rest of the clip is black");
    return nullptr;
  }
  if (serial) *serial = cl.serial;
  return cl.has_cur ? &cl.cur : nullptr;
}

void FramePool::trim(const TlPlan&, Ticks t) {
  for (auto it = clips_.begin(); it != clips_.end();) {
    const Clip& c = it->second;
    if (t < c.begin - 2 * kTicksPerSecond || t >= c.end + kTicksPerSecond) {
      closed_errors_ += c.dec ? c.dec->decode_errors() : 0;
      it = clips_.erase(it);
    } else {
      ++it;
    }
  }
}

int64_t FramePool::decode_errors() const {
  int64_t n = closed_errors_;
  for (const auto& [k, c] : clips_) n += c.dec ? c.dec->decode_errors() : 0;
  return n;
}

std::vector<std::string> FramePool::take_warnings() {
  std::vector<std::string> w;
  w.swap(warnings_);
  return w;
}

// ------------------------------------------------------------ compositor

namespace {

int sws_coeffs(const AVFrame* f) {
  switch (f->colorspace) {
    case AVCOL_SPC_BT709: return SWS_CS_ITU709;
    case AVCOL_SPC_BT2020_NCL:
    case AVCOL_SPC_BT2020_CL: return SWS_CS_BT2020;
    case AVCOL_SPC_SMPTE170M:
    case AVCOL_SPC_BT470BG: return SWS_CS_ITU601;
    default: return f->height >= 720 ? SWS_CS_ITU709 : SWS_CS_ITU601;
  }
}

void fill_black(Rgba img) {
  for (int y = 0; y < img.h; ++y) {
    auto* p = reinterpret_cast<uint32_t*>(img.row(y));
    uint32_t black;
    const uint8_t px[4] = {0, 0, 0, 255};
    std::memcpy(&black, px, 4);
    std::fill(p, p + img.w, black);
  }
}

}  // namespace

void convert_parallel(AVPixelFormat sf, const uint8_t* const src[4], const int sls[4], AVPixelFormat df, uint8_t* const dst[4],
                      const int dls[4], int w, int h, int src_cs, int src_full, int dst_cs, int dst_full, int flags) {
  const AVPixFmtDescriptor* sd = av_pix_fmt_desc_get(sf);
  const AVPixFmtDescriptor* dd = av_pix_fmt_desc_get(df);
  if (!sd || !dd) throw MediaError("unknown pixel format");
  const int sh = sd->log2_chroma_h, dh = dd->log2_chroma_h;
  const int align = 1 << std::max(1, std::max(sh, dh));
  const int bands = std::min(static_cast<int>(WorkPool::shared().threads()) * 2, h / 64);
  const int band = bands > 1 ? ((h + bands - 1) / bands + align - 1) / align * align : h;
  const int n = (h + band - 1) / band;
  WorkPool::shared().parallel(n < 8 && n > 1 ? 8 : n, [&](int b, int e) {
    // One context per band height and thread (bands are the same height but the last).
    struct Contexts {
      std::map<int, SwsContext*> by_height;
      ~Contexts() {
        for (auto& [k, c] : by_height) sws_freeContext(c);
      }
    };
    thread_local Contexts ctx;
    for (int i = b; i < e && i < n; ++i) {
      const int y0 = i * band, bh = std::min(h, y0 + band) - y0;
      if (bh <= 0) continue;
      SwsContext*& c = ctx.by_height[bh];
      c = sws_getCachedContext(c, w, bh, sf, w, bh, df, flags, nullptr, nullptr, nullptr);
      if (!c) continue;
      sws_setColorspaceDetails(c, sws_getCoefficients(src_cs), src_full, sws_getCoefficients(dst_cs), dst_full, 0, 1 << 16, 1 << 16);
      const uint8_t* sp[4] = {nullptr, nullptr, nullptr, nullptr};
      uint8_t* dp[4] = {nullptr, nullptr, nullptr, nullptr};
      for (int q = 0; q < 4; ++q) {
        if (src[q]) sp[q] = src[q] + static_cast<ptrdiff_t>(y0 >> ((q == 1 || q == 2) ? sh : 0)) * sls[q];
        if (dst[q]) dp[q] = dst[q] + static_cast<ptrdiff_t>(y0 >> ((q == 1 || q == 2) ? dh : 0)) * dls[q];
      }
      sws_scale(c, sp, sls, 0, bh, dp, dls);
    }
  });
}

Compositor::Compositor(int width, int height, DecodeOptions opts) : w_(width), h_(height), pool_([&] {
  opts.native = true;
  opts.max_width = 0;
  opts.max_height = 0;
  return opts;
}()) {
  out_.resize(w_, h_);
  fill_black(out_.view());
}

Compositor::~Compositor() {
  for (auto*& s : sws_) {
    if (s) sws_freeContext(s);
    s = nullptr;
  }
}

void Compositor::draw_frame(const VideoFrame& vf, Rgba dst, int slot) {
  fill_black(dst);
  if (!vf.native) return;
  const AVFrame* f = vf.native.get();
  int x0, y0, fw, fh;
  fit_rect(vf.width, vf.height, dst.w, dst.h, &x0, &y0, &fw, &fh);
  const bool side = vf.rotation == 90 || vf.rotation == 270;
  const int sw_w = side ? fh : fw, sw_h = side ? fw : fh;  // before rotation
  const bool same = sw_w == f->width && sw_h == f->height;
  SwsContext*& sws = sws_[slot & 1];
  sws = sws_getCachedContext(sws, f->width, f->height, static_cast<AVPixelFormat>(f->format), sw_w, sw_h, AV_PIX_FMT_RGBA,
                             same ? SWS_POINT : SWS_BICUBIC, nullptr, nullptr, nullptr);
  if (!sws) throw MediaError("cannot convert the picture");
  sws_setColorspaceDetails(sws, sws_getCoefficients(sws_coeffs(f)), f->color_range == AVCOL_RANGE_JPEG ? 1 : 0, sws_getCoefficients(SWS_CS_DEFAULT), 1, 0,
                           1 << 16, 1 << 16);
  if (vf.rotation == 0 && same) {
    // Same size (the export, or a preview at the source size): in bands.
    uint8_t* d[4] = {dst.row(y0) + static_cast<size_t>(x0) * 4, nullptr, nullptr, nullptr};
    int ls[4] = {dst.stride, 0, 0, 0};
    convert_parallel(static_cast<AVPixelFormat>(f->format), f->data, f->linesize, AV_PIX_FMT_RGBA, d, ls, f->width, f->height, sws_coeffs(f),
                     f->color_range == AVCOL_RANGE_JPEG ? 1 : 0, SWS_CS_DEFAULT, 1, SWS_POINT);
  } else if (vf.rotation == 0) {
    uint8_t* d[4] = {dst.row(y0) + static_cast<size_t>(x0) * 4, nullptr, nullptr, nullptr};
    int ls[4] = {dst.stride, 0, 0, 0};
    sws_scale(sws, f->data, f->linesize, 0, f->height, d, ls);
  } else {
    rot_.resize(static_cast<size_t>(sw_w) * sw_h * 4);
    uint8_t* d[4] = {rot_.data(), nullptr, nullptr, nullptr};
    int ls[4] = {sw_w * 4, 0, 0, 0};
    sws_scale(sws, f->data, f->linesize, 0, f->height, d, ls);
    const auto* src = reinterpret_cast<const uint32_t*>(rot_.data());
    for (int y = 0; y < sw_h; ++y) {
      for (int x = 0; x < sw_w; ++x) {
        int dx, dy;
        if (vf.rotation == 90) {
          dx = sw_h - 1 - y;
          dy = x;
        } else if (vf.rotation == 180) {
          dx = sw_w - 1 - x;
          dy = sw_h - 1 - y;
        } else {  // 270
          dx = y;
          dy = sw_w - 1 - x;
        }
        std::memcpy(dst.row(y0 + dy) + static_cast<size_t>(x0 + dx) * 4, &src[static_cast<size_t>(y) * sw_w + x], 4);
      }
    }
  }
  const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(static_cast<AVPixelFormat>(f->format));
  if (desc && (desc->flags & AV_PIX_FMT_FLAG_ALPHA)) {
    // Transparent photo: over black.
    for (int y = 0; y < fh; ++y) {
      uint8_t* p = dst.row(y0 + y) + static_cast<size_t>(x0) * 4;
      for (int x = 0; x < fw; ++x, p += 4) {
        const unsigned a = p[3];
        for (int k = 0; k < 3; ++k) p[k] = static_cast<uint8_t>((p[k] * a + 127) / 255);
        p[3] = 255;
      }
    }
  }
}

void Compositor::draw_clip(const TlClip& c, const VideoFrame* f, Ticks t, Rgba dst, int slot) {
  if (!f) {
    fill_black(dst);
    return;
  }
  draw_frame(*f, dst, slot);
  if (!c.effects.empty()) {
    int x, y, w, h;
    fit_rect(f->width, f->height, dst.w, dst.h, &x, &y, &w, &h);
    apply_effects(c.effects, dst, x, y, w, h, dst.h);
  }
  const double level = video_fade_level(c, t);
  if (level < 1) apply_fade(dst, level, 0);
}

bool Compositor::render(const TlPlan& plan, Ticks t, bool* black) {
  const Composition k = compose_at(plan, t);
  pool_.trim(plan, t);
  int64_t sa = 0, sb = 0;
  const VideoFrame* fa = k.a ? pool_.frame(*k.a, k.a_src, &sa) : nullptr;
  const VideoFrame* fb = k.b ? pool_.frame(*k.b, k.b_src, &sb) : nullptr;
  // Same sources, same levels: the same picture.
  std::string key;
  if (k.a) {
    key = k.a->id + '#' + std::to_string(sa) + (fa ? "" : "x") + '@' + std::to_string(std::lround(video_fade_level(*k.a, t) * 4096)) + '@' +
          std::to_string(std::lround(k.dip * 4096)) + '/' + std::to_string(k.dip_toward);
  }
  if (k.b) {
    key += '|' + k.b->id + '#' + std::to_string(sb) + (fb ? "" : "x") + '@' + std::to_string(std::lround(video_fade_level(*k.b, t) * 4096)) + '@' +
           std::to_string(static_cast<int>(k.kind)) + '/' + std::to_string(static_cast<int>(k.dir)) + '/' + std::to_string(std::lround(k.progress * 100000));
  }
  if (key.empty()) key = "black";
  if (black) *black = !k.a;
  if (key == key_) return false;
  key_ = key;
  Rgba out = out_.view();
  if (!k.a) {
    fill_black(out);
  } else if (!k.b) {
    draw_clip(*k.a, fa, t, out, 0);
    if (k.dip < 1) apply_fade(out, k.dip, k.dip_toward);
  } else {
    a_buf_.resize(w_, h_);
    b_buf_.resize(w_, h_);
    draw_clip(*k.a, fa, t, a_buf_.view(), 0);
    draw_clip(*k.b, fb, t, b_buf_.view(), 1);
    apply_transition(k.kind, k.dir, k.progress, a_buf_.view(), b_buf_.view(), out);
  }
  return true;
}

}  // namespace cutlab::media
