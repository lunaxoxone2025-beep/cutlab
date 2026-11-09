// The picture of a timeline at one instant, composed with effects, video
// fades and transitions (internal header).
//
// Shared by the preview (TimelinePlayer, at preview size) and the export
// (Exporter, at the output size): both ask for the picture at timeline time
// t and get the same decoded source frames, the same effects with the same
// parameters, in the same order:
//
//   source frame (original media) → fit into the frame (black bars)
//   → clip effects in order → clip video fade → transition with the
//   neighbouring clip (or dip to a colour)
//
// Titles are drawn on top by the exporter (the monitor draws them itself).
#pragma once

#include <map>
#include <memory>
#include <string>
#include <vector>

#include "effects.hpp"
#include "timeline.hpp"

namespace cutlab::media {

/// What is visible at one instant.
struct Composition {
  const TlClip* a = nullptr;  // null = black
  Ticks a_src = 0;            // source time of a
  const TlClip* b = nullptr;  // overlap transition: the incoming clip
  Ticks b_src = 0;
  TransitionKind kind = TransitionKind::dissolve;
  Direction dir = Direction::left;
  double progress = 0;  // overlap transition progress 0..1
  double dip = 1;       // dip transitions: level of a (1 = none)
  int dip_toward = 0;   // 0 black, 255 white
  /// Needs the compositor (effects, fades, transitions); false = a plain
  /// picture the exporter may convert directly.
  bool styled() const;
};

Composition compose_at(const TlPlan& plan, Ticks t);

/// Video fade level of clip c at timeline time t (1 = none).
double video_fade_level(const TlClip& c, Ticks t);

/// Where a picture of size pw × ph goes inside a W × H frame (fit, centred,
/// even sizes and positions so YUV 4:2:0 output lines up).
void fit_rect(int pw, int ph, int W, int H, int* x, int* y, int* w, int* h);

/// A same-size pixel format conversion (sws_scale is single-threaded),
/// split into bands of rows over the worker pool. Colour spaces as for
/// sws_setColorspaceDetails (coefficient table ids, full-range flags).
void convert_parallel(AVPixelFormat sf, const uint8_t* const src[4], const int sls[4], AVPixelFormat df, uint8_t* const dst[4],
                      const int dls[4], int w, int h, int src_cs, int src_full, int dst_cs, int dst_full, int flags);

/// Decoded pictures of the clips in use (one decoder per clip, kept while
/// the clip is near the requested times, reused across transitions).
class FramePool {
 public:
  explicit FramePool(DecodeOptions opts) : opts_(opts) {}
  /// The frame displayed at source time `src` of clip c (null: unreadable).
  /// *serial changes whenever the returned picture changes.
  const VideoFrame* frame(const TlClip& c, Ticks src, int64_t* serial);
  /// Closes decoders of clips far from timeline time t.
  void trim(const TlPlan& plan, Ticks t);
  void clear() { clips_.clear(); }
  int open_decoders() const { return static_cast<int>(clips_.size()); }
  int64_t decode_errors() const;
  std::vector<std::string> take_warnings();
  std::string decoder_name() const { return last_name_; }
  bool hardware() const { return last_hw_; }

 private:
  struct Clip {
    std::unique_ptr<VideoDecoder> dec;
    VideoFrame cur, nxt;
    bool has_cur = false, has_nxt = false;
    bool failed = false;
    bool still = false;
    int64_t serial = 0;
    Ticks begin = 0, end = 0;  // timeline range the clip is shown in
  };
  DecodeOptions opts_;
  std::map<std::string, Clip> clips_;
  std::vector<std::string> warnings_;
  int64_t closed_errors_ = 0;
  std::string last_name_;
  bool last_hw_ = false;
};

/// Composes pictures (RGBA, full range) at a fixed size.
class Compositor {
 public:
  Compositor(int width, int height, DecodeOptions opts);
  ~Compositor();
  Compositor(const Compositor&) = delete;
  Compositor& operator=(const Compositor&) = delete;

  int width() const { return w_; }
  int height() const { return h_; }
  FramePool& pool() { return pool_; }

  /// Composes the picture at t. Returns false when it is the same picture
  /// as the previous call (nothing redrawn; `out` keeps it). *black: nothing
  /// visible (out is black).
  bool render(const TlPlan& plan, Ticks t, bool* black);
  const RgbaBuffer& picture() const { return out_; }
  /// Forget the previous picture (the next render always draws).
  void invalidate() { key_.clear(); }

  /// The RGBA picture of one source frame fitted into a w × h frame (black
  /// bars, rotation, transparent photos over black).
  void draw_frame(const VideoFrame& f, Rgba dst, int slot);

 private:
  void draw_clip(const TlClip& c, const VideoFrame* f, Ticks t, Rgba dst, int slot);

  int w_, h_;
  FramePool pool_;
  RgbaBuffer out_, b_buf_, a_buf_;
  std::vector<uint8_t> rot_;
  struct SwsContext* sws_[2] = {nullptr, nullptr};
  std::string key_;
};

}  // namespace cutlab::media
