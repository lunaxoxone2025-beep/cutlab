#include "probe.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>
#include <cstdio>
#include <sstream>

#include "json.hpp"

namespace cutlab::media {
namespace {

Rational to_rational(AVRational r) {
  if (r.num <= 0 || r.den <= 0) return Rational{0, 1};
  return Rational::make(r.num, r.den);
}

// Looks at the timestamps of the first video packets: if the gaps between
// frames differ by more than rounding allows, the frame rate is variable.
// Containers like MKV store no average rate, so metadata alone cannot tell.
bool sample_variable_frame_rate(AVFormatContext* fmt, int stream, double* measured_fps) {
  const AVStream* st = fmt->streams[stream];
  std::vector<int64_t> pts;
  PacketPtr pkt = make_packet();
  while (pts.size() < 240) {
    const int r = av_read_frame(fmt, pkt.get());
    if (r < 0) break;
    if (pkt->stream_index == stream && pkt->pts != AV_NOPTS_VALUE) pts.push_back(pkt->pts);
    av_packet_unref(pkt.get());
  }
  if (pts.size() < 16) return false;
  std::sort(pts.begin(), pts.end());  // decode order -> presentation order
  // With B-frames the last packets in decode order leave holes at the end of
  // the sorted window: ignore its tail.
  pts.resize(pts.size() - 8);
  int64_t lo = INT64_MAX, hi = 0;
  for (size_t i = 1; i < pts.size(); ++i) {
    const int64_t d = pts[i] - pts[i - 1];
    if (d <= 0) continue;
    lo = std::min(lo, d);
    hi = std::max(hi, d);
  }
  if (lo == INT64_MAX) return false;
  const double span = static_cast<double>(pts.back() - pts.front()) * av_q2d(st->time_base);
  if (measured_fps && span > 0) *measured_fps = static_cast<double>(pts.size() - 1) / span;
  // Timestamps rounded to the time base (e.g. 1 ms in MKV) jitter by one unit.
  return hi - lo > std::max<int64_t>(2, lo / 4);
}

bool is_still_image_format(const AVFormatContext* fmt) {
  const char* name = fmt->iformat ? fmt->iformat->name : "";
  const std::string n = name;
  return n == "image2" || n.find("_pipe") != std::string::npos;
}

}  // namespace

ProbeResult probe(const Source& src) {
  Demuxer demux(src);
  AVFormatContext* fmt = demux.fmt();
  ProbeResult r;
  r.container = fmt->iformat ? fmt->iformat->name : "";
  r.bit_rate = fmt->bit_rate;
  if (fmt->pb) {
    const int64_t size = avio_size(fmt->pb);
    if (size >= 0) r.size_bytes = size;
  }
  if (fmt->start_time != AV_NOPTS_VALUE) r.start_time = pts_to_ticks(fmt->start_time, AVRational{1, AV_TIME_BASE});

  const bool still = is_still_image_format(fmt);
  const int vi = demux.best_stream(AVMEDIA_TYPE_VIDEO);
  if (vi >= 0) {
    const AVStream* st = fmt->streams[vi];
    const AVCodecParameters* par = st->codecpar;
    auto& v = r.video;
    v.present = true;
    v.codec = avcodec_get_name(par->codec_id);
    v.coded_width = par->width;
    v.coded_height = par->height;
    v.rotation = stream_rotation(st);
    const bool side = v.rotation == 90 || v.rotation == 270;
    v.width = side ? par->height : par->width;
    v.height = side ? par->width : par->height;
    v.still_image = still;
    v.frame_rate = to_rational(st->avg_frame_rate);
    v.base_frame_rate = to_rational(st->r_frame_rate);
    if (v.frame_rate.num == 0) v.frame_rate = v.base_frame_rate;
    // r_frame_rate is the smallest rate that can express every timestamp; when
    // it differs noticeably from the average, frame durations vary (VFR).
    if (!still && v.frame_rate.num > 0 && v.base_frame_rate.num > 0) {
      const double avg = v.frame_rate.to_double();
      const double base = v.base_frame_rate.to_double();
      v.variable_frame_rate = std::fabs(avg - base) / base > 0.01;
    }
    if (!still && !v.variable_frame_rate) {
      double measured = 0;
      v.variable_frame_rate = sample_variable_frame_rate(fmt, vi, &measured);
    }
    v.frame_count = st->nb_frames > 0 ? st->nb_frames : 0;
    const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(static_cast<AVPixelFormat>(par->format));
    if (desc) {
      v.pixel_format = desc->name;
      v.bit_depth = desc->comp[0].depth;
    }
  }
  const int ai = demux.best_stream(AVMEDIA_TYPE_AUDIO);
  if (ai >= 0) {
    const AVCodecParameters* par = fmt->streams[ai]->codecpar;
    auto& a = r.audio;
    a.present = true;
    a.codec = avcodec_get_name(par->codec_id);
    a.sample_rate = par->sample_rate;
    a.channels = par->ch_layout.nb_channels;
    char layout[128] = {0};
    if (av_channel_layout_describe(&par->ch_layout, layout, sizeof layout) > 0) a.channel_layout = layout;
  }

  if (!still) {
    if (fmt->duration != AV_NOPTS_VALUE && fmt->duration > 0) {
      r.duration = pts_to_ticks(fmt->duration, AVRational{1, AV_TIME_BASE});
    } else {
      // Some containers only know per-stream durations.
      for (unsigned i = 0; i < fmt->nb_streams; ++i) {
        const AVStream* st = fmt->streams[i];
        if (st->duration > 0) r.duration = std::max(r.duration, pts_to_ticks(st->duration, st->time_base));
      }
    }
  }
  if (!r.video.present && !r.audio.present) throw MediaError("no audio or video stream in " + src.describe());
  return r;
}

std::string ProbeResult::to_json() const {
  JsonWriter j;
  j.begin_object();
  j.key("container").value(container);
  j.key("durationTicks").value(duration);
  j.key("startTicks").value(start_time);
  j.key("bitRate").value(bit_rate);
  j.key("sizeBytes").value(size_bytes);
  j.key("video");
  if (video.present) {
    j.begin_object();
    j.key("codec").value(video.codec);
    j.key("width").value(video.width);
    j.key("height").value(video.height);
    j.key("codedWidth").value(video.coded_width);
    j.key("codedHeight").value(video.coded_height);
    j.key("rotation").value(video.rotation);
    j.key("frameRate").begin_object().key("num").value(video.frame_rate.num).key("den").value(video.frame_rate.den).end_object();
    j.key("baseFrameRate")
        .begin_object()
        .key("num")
        .value(video.base_frame_rate.num)
        .key("den")
        .value(video.base_frame_rate.den)
        .end_object();
    j.key("variableFrameRate").value(video.variable_frame_rate);
    j.key("frameCount").value(video.frame_count);
    j.key("pixelFormat").value(video.pixel_format);
    j.key("bitDepth").value(video.bit_depth);
    j.key("stillImage").value(video.still_image);
    j.end_object();
  } else {
    j.null();
  }
  j.key("audio");
  if (audio.present) {
    j.begin_object();
    j.key("codec").value(audio.codec);
    j.key("sampleRate").value(audio.sample_rate);
    j.key("channels").value(audio.channels);
    j.key("channelLayout").value(audio.channel_layout);
    j.end_object();
  } else {
    j.null();
  }
  j.end_object();
  return j.str();
}

}  // namespace cutlab::media
