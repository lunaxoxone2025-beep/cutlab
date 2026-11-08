// Frame-accurate video decoding (internal header).
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "demuxer.hpp"

namespace cutlab::media {

struct DecodeOptions {
  int max_width = 0;   // 0 = full size; output keeps the aspect ratio
  int max_height = 0;
  bool prefer_hardware = false;
  bool keyframes_only = false;  // thumbnails: skip everything but keyframes
  int threads = 0;              // 0 = automatic
};

/// A decoded frame converted to tightly packed RGBA (width * 4 bytes per row),
/// with the stream rotation already applied.
struct VideoFrame {
  Ticks pts = 0;        // media time (container start = 0)
  Ticks duration = 0;
  int width = 0;
  int height = 0;
  bool keyframe = false;
  std::vector<uint8_t> rgba;
};

/// Decodes one video stream. Only the packets needed for the requested
/// frames are read; memory use does not depend on the file length.
class VideoDecoder {
 public:
  VideoDecoder(const Source& src, DecodeOptions opts);
  ~VideoDecoder();
  VideoDecoder(const VideoDecoder&) = delete;
  VideoDecoder& operator=(const VideoDecoder&) = delete;

  /// Positions the decoder at media time `t`.
  /// accurate: the next frame returned is the one *displayed* at t (the last
  ///           frame whose pts <= t), found by decoding from the previous keyframe.
  /// fast:     the next frame is the keyframe at or before t (for scrubbing).
  void seek(Ticks t, bool accurate);

  /// Next frame in presentation order; false at end of stream.
  bool next(VideoFrame& out);

  bool frame_at(Ticks t, VideoFrame& out, bool accurate = true) {
    seek(t, accurate);
    return next(out);
  }

  Ticks duration() const { return duration_; }
  Rational frame_rate() const { return frame_rate_; }
  bool still_image() const { return still_; }
  bool hardware() const { return hw_active_; }
  const std::string& decoder_name() const { return decoder_name_; }
  int64_t decode_errors() const { return decode_errors_; }

 private:
  void open_codec(bool try_hardware);
  bool pull(FramePtr& out);
  bool pull_raw(FramePtr& out);
  void convert(const AVFrame* f, VideoFrame& out);
  Ticks frame_pts(const AVFrame* f);
  void raw_seek(Ticks t);
  static AVPixelFormat pick_hw_format(AVCodecContext* ctx, const AVPixelFormat* fmts);

  Demuxer demux_;
  DecodeOptions opts_;
  int stream_ = -1;
  AVStream* st_ = nullptr;
  CodecContextPtr ctx_;
  AVBufferRef* hw_device_ = nullptr;
  AVPixelFormat hw_format_ = AV_PIX_FMT_NONE;
  bool hw_active_ = false;
  std::string decoder_name_;

  PacketPtr pkt_;
  FramePtr pending_;
  bool eof_sent_ = false;
  bool have_target_ = false;
  Ticks target_ = 0;
  Ticks start_ = 0;  // container start time, subtracted from every pts
  Ticks duration_ = 0;
  Ticks last_pts_ = -1;
  Ticks default_frame_duration_ = 0;
  Ticks target_slack_ = 0;
  Rational frame_rate_{0, 1};
  int rotation_ = 0;
  bool still_ = false;
  bool still_done_ = false;
  int64_t decode_errors_ = 0;

  SwsContext* sws_ = nullptr;
  std::vector<uint8_t> scratch_;
};

}  // namespace cutlab::media
