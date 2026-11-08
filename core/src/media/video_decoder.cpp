#include "video_decoder.hpp"

#include "../diag/diag.hpp"

#include <algorithm>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>

namespace cutlab::media {
namespace {

bool is_still_format(const AVFormatContext* fmt) {
  const std::string n = fmt->iformat ? fmt->iformat->name : "";
  return n == "image2" || n.find("_pipe") != std::string::npos;
}

int sws_colorspace(const AVFrame* f) {
  switch (f->colorspace) {
    case AVCOL_SPC_BT709: return SWS_CS_ITU709;
    case AVCOL_SPC_BT2020_NCL:
    case AVCOL_SPC_BT2020_CL: return SWS_CS_BT2020;
    case AVCOL_SPC_SMPTE170M:
    case AVCOL_SPC_BT470BG: return SWS_CS_ITU601;
    default: return f->height >= 720 ? SWS_CS_ITU709 : SWS_CS_ITU601;  // usual convention for untagged video
  }
}

void fit_within(int w, int h, int max_w, int max_h, int& out_w, int& out_h) {
  out_w = w;
  out_h = h;
  if (max_w > 0 && out_w > max_w) {
    out_h = static_cast<int>(static_cast<int64_t>(out_h) * max_w / out_w);
    out_w = max_w;
  }
  if (max_h > 0 && out_h > max_h) {
    out_w = static_cast<int>(static_cast<int64_t>(out_w) * max_h / out_h);
    out_h = max_h;
  }
  out_w = std::max(2, out_w & ~1);
  out_h = std::max(2, out_h & ~1);
}

// One-shot decoders (timeline frames, thumbnails) share a pixel budget so
// several big decodes cannot pile up at once: one 4K picture, or four
// 1080p ones, may be decoding at the same time; the rest wait their turn.
// (A 4K 10-bit HEVC decoder holds ~200 MB of reference pictures.)
constexpr int64_t kOneShotBudget = 3840LL * 2160;
std::mutex g_budget_mu;
std::condition_variable g_budget_cv;
int64_t g_budget_used = 0;

int64_t acquire_budget(int64_t pixels) {
  pixels = std::min(std::max<int64_t>(pixels, 1), kOneShotBudget);
  std::unique_lock<std::mutex> lock(g_budget_mu);
  g_budget_cv.wait(lock, [&] { return g_budget_used + pixels <= kOneShotBudget; });
  g_budget_used += pixels;
  return pixels;
}

void release_budget(int64_t pixels) {
  if (pixels <= 0) return;
  {
    std::lock_guard<std::mutex> lock(g_budget_mu);
    g_budget_used -= pixels;
  }
  g_budget_cv.notify_all();
}

}  // namespace

int decoder_threads(int width, int height, bool one_shot, unsigned cpus) {
  const int cores = static_cast<int>(std::max(1u, cpus));
  const int64_t pixels = static_cast<int64_t>(std::max(1, width)) * std::max(1, height);
  if (one_shot) return std::min(cores, 2);
  int cap = 6;
  if (pixels > 2560 * 1440) {
    cap = 3;  // 4K and above
  } else if (pixels > 1920 * 1080) {
    cap = 4;
  }
  return std::max(1, std::min(cores, cap));
}

VideoDecoder::VideoDecoder(const Source& src, DecodeOptions opts) : demux_(src), opts_(opts) {
  AVFormatContext* fmt = demux_.fmt();
  stream_ = demux_.best_stream(AVMEDIA_TYPE_VIDEO);
  if (stream_ < 0) throw MediaError("no video stream in " + src.describe());
  st_ = fmt->streams[stream_];
  // Only read the stream we decode.
  for (unsigned i = 0; i < fmt->nb_streams; ++i) {
    if (static_cast<int>(i) != stream_) fmt->streams[i]->discard = AVDISCARD_ALL;
  }
  still_ = is_still_format(fmt);
  rotation_ = stream_rotation(st_);
  if (fmt->start_time != AV_NOPTS_VALUE) start_ = pts_to_ticks(fmt->start_time, AVRational{1, AV_TIME_BASE});
  if (!still_ && fmt->duration != AV_NOPTS_VALUE && fmt->duration > 0) {
    duration_ = pts_to_ticks(fmt->duration, AVRational{1, AV_TIME_BASE});
  }
  AVRational fr = st_->avg_frame_rate.num > 0 ? st_->avg_frame_rate : st_->r_frame_rate;
  if (fr.num > 0 && fr.den > 0) {
    frame_rate_ = Rational::make(fr.num, fr.den);
    default_frame_duration_ = frames_to_ticks(1, frame_rate_);
  } else {
    default_frame_duration_ = kTicksPerSecond / 30;
  }
  target_slack_ = std::min(pts_to_ticks(1, st_->time_base), default_frame_duration_ / 2);
  pkt_ = make_packet();
  if (opts_.one_shot || opts_.keyframes_only) {
    budget_ = acquire_budget(static_cast<int64_t>(st_->codecpar->width) * st_->codecpar->height);
  }
  try {
    open_codec(opts_.prefer_hardware);
  } catch (...) {
    release_budget(budget_);
    throw;
  }
}

VideoDecoder::~VideoDecoder() {
  release_codec();
  if (sws_) sws_freeContext(sws_);
  release_budget(budget_);
}

void VideoDecoder::release_codec() {
  ctx_.reset();
  if (hw_device_) av_buffer_unref(&hw_device_);
  if (hw_counted_) {
    diag::hardware_decoder_closed();
    hw_counted_ = false;
  }
}

AVPixelFormat VideoDecoder::pick_hw_format(AVCodecContext* ctx, const AVPixelFormat* fmts) {
  const auto* self = static_cast<const VideoDecoder*>(ctx->opaque);
  for (const AVPixelFormat* p = fmts; *p != AV_PIX_FMT_NONE; ++p) {
    if (*p == self->hw_format_) return *p;
  }
  // The hardware path is not offered for this stream: take the first software format.
  for (const AVPixelFormat* p = fmts; *p != AV_PIX_FMT_NONE; ++p) {
    const AVPixFmtDescriptor* d = av_pix_fmt_desc_get(*p);
    if (d && !(d->flags & AV_PIX_FMT_FLAG_HWACCEL)) return *p;
  }
  return AV_PIX_FMT_NONE;
}

void VideoDecoder::open_codec(bool try_hardware) {
  release_codec();
  hw_active_ = false;
  hw_format_ = AV_PIX_FMT_NONE;

  const AVCodec* codec = nullptr;
#ifdef __ANDROID__
  // MediaCodec hardware decoders are separate FFmpeg decoders ("h264_mediacodec").
  if (try_hardware && !opts_.keyframes_only) {
    const std::string name = std::string(avcodec_get_name(st_->codecpar->codec_id)) + "_mediacodec";
    codec = avcodec_find_decoder_by_name(name.c_str());
  }
#endif
  const bool mediacodec = codec != nullptr;
  if (!codec) codec = avcodec_find_decoder(st_->codecpar->codec_id);
  if (!codec) throw MediaError(std::string("no decoder for ") + avcodec_get_name(st_->codecpar->codec_id));

  CodecContextPtr ctx(avcodec_alloc_context3(codec));
  if (!ctx) throw MediaError("out of memory (codec)");
  check(avcodec_parameters_to_context(ctx.get(), st_->codecpar), "codec parameters");
  ctx->pkt_timebase = st_->time_base;
  ctx->opaque = this;
  if (opts_.keyframes_only) ctx->skip_frame = AVDISCARD_NONKEY;

#ifndef __ANDROID__
  if (try_hardware && !opts_.keyframes_only) {
    static const AVHWDeviceType kPreferred[] = {AV_HWDEVICE_TYPE_D3D11VA, AV_HWDEVICE_TYPE_DXVA2, AV_HWDEVICE_TYPE_VAAPI,
                                                AV_HWDEVICE_TYPE_VIDEOTOOLBOX};
    for (const AVHWDeviceType type : kPreferred) {
      if (hw_device_) break;
      for (int i = 0;; ++i) {
        const AVCodecHWConfig* cfg = avcodec_get_hw_config(codec, i);
        if (!cfg) break;
        if (cfg->device_type != type || !(cfg->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) continue;
        if (av_hwdevice_ctx_create(&hw_device_, type, nullptr, nullptr, 0) == 0) {
          hw_format_ = cfg->pix_fmt;
          ctx->hw_device_ctx = av_buffer_ref(hw_device_);
          ctx->get_format = &VideoDecoder::pick_hw_format;
        }
        break;
      }
    }
  }
#endif
  threads_ = 1;
  if (!hw_device_ && !mediacodec) {
    threads_ = opts_.threads > 0 ? opts_.threads
                                 : decoder_threads(st_->codecpar->width, st_->codecpar->height, opts_.one_shot || opts_.keyframes_only,
                                                   std::thread::hardware_concurrency());
    ctx->thread_count = threads_;
    // Frame threads keep one picture per thread in flight; a few frames
    // only need slice threads (less memory, no start-up delay).
    ctx->thread_type = (opts_.one_shot || opts_.keyframes_only) ? FF_THREAD_SLICE : (FF_THREAD_FRAME | FF_THREAD_SLICE);
  }

  const int err = avcodec_open2(ctx.get(), codec, nullptr);
  if (err < 0) {
    if (try_hardware && (hw_device_ || mediacodec)) {
      // Hardware unavailable for this stream: software decode.
      hw_fallback_ = std::string(codec->name) + " could not start: " + av_error_string(err);
      diag::note("hardware decoder %s failed to open (%s): using software", codec->name, av_error_string(err).c_str());
      ctx.reset();
      if (hw_device_) av_buffer_unref(&hw_device_);
      open_codec(false);
      return;
    }
    throw MediaError("cannot open decoder " + std::string(codec->name) + ": " + av_error_string(err));
  }
  hw_active_ = hw_device_ != nullptr || mediacodec;
  decoder_name_ = codec->name;
  if (hw_device_) {
    const auto* dev = reinterpret_cast<const AVHWDeviceContext*>(hw_device_->data);
    decoder_name_ += std::string(" (") + av_hwdevice_get_type_name(dev->type) + ")";
  }
  if (hw_active_) {
    diag::hardware_decoder_opened();
    hw_counted_ = true;
  }
  ctx_ = std::move(ctx);
  eof_sent_ = false;
  if (!opts_.one_shot && !opts_.keyframes_only) {
    int64_t rss = 0, peak = 0;
    diag::memory_kib(&rss, &peak);
    diag::note("decoder %s %s %dx%d %d-bit threads=%d hw=%d rss=%lldMB", decoder_name_.c_str(), avcodec_get_name(st_->codecpar->codec_id),
               st_->codecpar->width, st_->codecpar->height,
               av_pix_fmt_desc_get(static_cast<AVPixelFormat>(st_->codecpar->format))
                   ? av_pix_fmt_desc_get(static_cast<AVPixelFormat>(st_->codecpar->format))->comp[0].depth
                   : 8,
               threads_, hw_active_ ? 1 : 0, static_cast<long long>(rss / 1024));
  }
}

Ticks VideoDecoder::frame_pts(const AVFrame* f) {
  int64_t ts = f->best_effort_timestamp;
  if (ts == AV_NOPTS_VALUE) ts = f->pts;
  if (ts == AV_NOPTS_VALUE) return last_pts_ < 0 ? 0 : last_pts_ + default_frame_duration_;
  return pts_to_ticks(ts, st_->time_base) - start_;
}

bool VideoDecoder::pull_raw(FramePtr& out) {
  out = make_frame();
  for (;;) {
    const int r = avcodec_receive_frame(ctx_.get(), out.get());
    if (r == 0) return true;
    if (r == AVERROR_EOF) return false;
    if (r != AVERROR(EAGAIN)) throw MediaError("decode: " + av_error_string(r));
    if (eof_sent_) return false;
    const int rr = av_read_frame(demux_.fmt(), pkt_.get());
    if (rr == AVERROR_EOF || (rr < 0 && avio_feof(demux_.fmt()->pb))) {
      avcodec_send_packet(ctx_.get(), nullptr);  // drain
      eof_sent_ = true;
      continue;
    }
    check(rr, "read");
    if (pkt_->stream_index != stream_) {
      av_packet_unref(pkt_.get());
      continue;
    }
    const int sr = avcodec_send_packet(ctx_.get(), pkt_.get());
    av_packet_unref(pkt_.get());
    if (sr < 0 && sr != AVERROR(EAGAIN)) ++decode_errors_;  // damaged packet: keep going
  }
}

bool VideoDecoder::pull_checked(FramePtr& out) {
  if (!pull_raw(out)) return false;
  if (out->hw_frames_ctx && out->format == hw_format_) {
    FramePtr sw = make_frame();
    check(av_hwframe_transfer_data(sw.get(), out.get(), 0), "hardware frame download");
    av_frame_copy_props(sw.get(), out.get());
    out = std::move(sw);
  }
  if (out->width <= 0 || out->height <= 0 || out->format < 0 || !out->data[0]) {
    throw MediaError("decoder returned an empty picture");
  }
  return true;
}

bool VideoDecoder::pull(FramePtr& out) {
  try {
    return pull_checked(out);
  } catch (const MediaError& e) {
    if (!hw_active_) throw;
    // A hardware decoder failed mid-stream: continue in software from here.
    hw_fallback_ = decoder_name_ + " failed while decoding: " + e.what();
    diag::note("hardware decoder %s failed (%s): switching to software", decoder_name_.c_str(), e.what());
    const Ticks resume = last_pts_ < 0 ? 0 : last_pts_;
    open_codec(false);
    raw_seek(resume);
    return pull_checked(out);
  }
}

void VideoDecoder::raw_seek(Ticks t) {
  const int64_t ts = ticks_to_pts(std::max<Ticks>(0, t) + start_, st_->time_base);
  int r = av_seek_frame(demux_.fmt(), stream_, ts, AVSEEK_FLAG_BACKWARD);
  if (r < 0) r = avformat_seek_file(demux_.fmt(), stream_, INT64_MIN, ts, ts, 0);
  if (r < 0) {
    // Not seekable this way (some raw streams): fall back to the beginning.
    av_seek_frame(demux_.fmt(), stream_, 0, AVSEEK_FLAG_BACKWARD | AVSEEK_FLAG_BYTE);
  }
  avcodec_flush_buffers(ctx_.get());
  pending_.reset();
  eof_sent_ = false;
}

void VideoDecoder::seek(Ticks t, bool accurate) {
  if (still_) {
    still_done_ = false;
    have_target_ = false;
    return;
  }
  raw_seek(t);
  have_target_ = accurate;
  target_ = t;
}

bool VideoDecoder::next(VideoFrame& out) {
  if (still_) {
    // A still image decodes once; every request returns it.
    if (still_done_ && !out.rgba.empty()) return true;
    raw_seek(0);
    FramePtr f;
    if (!pull(f)) return false;
    convert(f.get(), out);
    out.pts = 0;
    out.duration = 0;
    still_done_ = true;
    return true;
  }
  if (have_target_) {
    have_target_ = false;
    FramePtr prev;
    Ticks back_off = kTicksPerSecond;
    int retries = 0;
    for (;;) {
      FramePtr f;
      if (!pull(f)) break;
      const Ticks pts = frame_pts(f.get());
      last_pts_ = pts;
      // Timestamps rounded to the container's time base (1 ms in MKV) can put
      // frame N a fraction of a millisecond after its exact time.
      if (pts <= target_ + target_slack_) {
        prev = std::move(f);
        continue;
      }
      if (!prev && retries < 3 && target_ > 0 && pts > target_ + default_frame_duration_) {
        ++retries;
        // The demuxer landed after the target (imprecise index): seek further back.
        raw_seek(target_ - back_off);
        back_off *= 4;
        continue;
      }
      if (prev) {
        pending_ = std::move(f);
        convert(prev.get(), out);
      } else {
        convert(f.get(), out);
      }
      return true;
    }
    if (!prev) return false;
    convert(prev.get(), out);
    return true;
  }
  if (pending_) {
    FramePtr f = std::move(pending_);
    convert(f.get(), out);
    return true;
  }
  FramePtr f;
  if (!pull(f)) return false;
  convert(f.get(), out);
  return true;
}

void VideoDecoder::convert(const AVFrame* f, VideoFrame& out) {
  const bool side = rotation_ == 90 || rotation_ == 270;
  const int disp_w = side ? f->height : f->width;
  const int disp_h = side ? f->width : f->height;
  int out_w = 0, out_h = 0;
  fit_within(disp_w, disp_h, opts_.max_width, opts_.max_height, out_w, out_h);
  const int scale_w = side ? out_h : out_w;  // size before rotation
  const int scale_h = side ? out_w : out_h;

  sws_ = sws_getCachedContext(sws_, f->width, f->height, static_cast<AVPixelFormat>(f->format), scale_w, scale_h, AV_PIX_FMT_RGBA,
                              SWS_BILINEAR, nullptr, nullptr, nullptr);
  if (!sws_) throw MediaError("cannot convert pixel format");
  const int cs = sws_colorspace(f);
  sws_setColorspaceDetails(sws_, sws_getCoefficients(cs), f->color_range == AVCOL_RANGE_JPEG ? 1 : 0, sws_getCoefficients(SWS_CS_DEFAULT), 1, 0,
                           1 << 16, 1 << 16);

  std::vector<uint8_t>& target = rotation_ == 0 ? out.rgba : scratch_;
  target.resize(static_cast<size_t>(scale_w) * scale_h * 4);
  uint8_t* dst[4] = {target.data(), nullptr, nullptr, nullptr};
  int dst_stride[4] = {scale_w * 4, 0, 0, 0};
  sws_scale(sws_, f->data, f->linesize, 0, f->height, dst, dst_stride);

  if (rotation_ != 0) {
    out.rgba.resize(static_cast<size_t>(out_w) * out_h * 4);
    const auto* src = reinterpret_cast<const uint32_t*>(scratch_.data());
    auto* d = reinterpret_cast<uint32_t*>(out.rgba.data());
    for (int y = 0; y < scale_h; ++y) {
      for (int x = 0; x < scale_w; ++x) {
        int dx = x, dy = y;
        if (rotation_ == 90) {
          dx = scale_h - 1 - y;
          dy = x;
        } else if (rotation_ == 180) {
          dx = scale_w - 1 - x;
          dy = scale_h - 1 - y;
        } else {  // 270
          dx = y;
          dy = scale_w - 1 - x;
        }
        d[static_cast<size_t>(dy) * out_w + dx] = src[static_cast<size_t>(y) * scale_w + x];
      }
    }
  }
  out.width = out_w;
  out.height = out_h;
  out.pts = frame_pts(f);
  out.duration = f->duration > 0 ? pts_to_ticks(f->duration, st_->time_base) : default_frame_duration_;
  out.keyframe = (f->flags & AV_FRAME_FLAG_KEY) != 0;
  last_pts_ = out.pts;
}

}  // namespace cutlab::media
