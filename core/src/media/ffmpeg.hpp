// Shared FFmpeg helpers for the media engine (internal header).
#pragma once

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/display.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}

#include <memory>
#include <stdexcept>
#include <string>

#include "cutlab/time.hpp"

namespace cutlab::media {

/// Error raised by the media engine; `what()` is a readable message.
class MediaError : public std::runtime_error {
 public:
  explicit MediaError(const std::string& msg) : std::runtime_error(msg) {}
};

std::string av_error_string(int err);

/// Throws MediaError("<what>: <ffmpeg message>") when err < 0.
inline void check(int err, const char* what) {
  if (err < 0) throw MediaError(std::string(what) + ": " + av_error_string(err));
}

struct FormatContextDeleter {
  void operator()(AVFormatContext* p) const { avformat_close_input(&p); }
};
struct CodecContextDeleter {
  void operator()(AVCodecContext* p) const { avcodec_free_context(&p); }
};
struct FrameDeleter {
  void operator()(AVFrame* p) const { av_frame_free(&p); }
};
struct PacketDeleter {
  void operator()(AVPacket* p) const { av_packet_free(&p); }
};
struct SwsDeleter {
  void operator()(SwsContext* p) const { sws_freeContext(p); }
};
struct SwrDeleter {
  void operator()(SwrContext* p) const { swr_free(&p); }
};
struct BufferRefDeleter {
  void operator()(AVBufferRef* p) const { av_buffer_unref(&p); }
};

using FramePtr = std::unique_ptr<AVFrame, FrameDeleter>;
using PacketPtr = std::unique_ptr<AVPacket, PacketDeleter>;
using CodecContextPtr = std::unique_ptr<AVCodecContext, CodecContextDeleter>;

inline FramePtr make_frame() {
  FramePtr f(av_frame_alloc());
  if (!f) throw MediaError("out of memory (frame)");
  return f;
}
inline PacketPtr make_packet() {
  PacketPtr p(av_packet_alloc());
  if (!p) throw MediaError("out of memory (packet)");
  return p;
}

/// Stream timestamp -> exact ticks.
inline Ticks pts_to_ticks(int64_t pts, AVRational tb) {
  return rescale(pts, Rational::make(tb.num, tb.den), Rational{1, kTicksPerSecond}, Rounding::Nearest);
}

/// Ticks -> stream timestamp (rounded down so seeking never lands after t).
inline int64_t ticks_to_pts(Ticks t, AVRational tb) {
  return rescale(t, Rational{1, kTicksPerSecond}, Rational::make(tb.num, tb.den), Rounding::Down);
}

/// Rotation in degrees (0, 90, 180, 270) from a stream's display matrix.
int stream_rotation(const AVStream* st);

}  // namespace cutlab::media
