#include "audio_decoder.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace cutlab::media {

AudioDecoder::AudioDecoder(const Source& src, int out_rate, int out_channels)
    : demux_(src), rate_(out_rate), channels_(out_channels) {
  if (out_rate <= 0 || out_channels <= 0 || out_channels > 8) throw MediaError("bad audio output format");
  AVFormatContext* fmt = demux_.fmt();
  stream_ = demux_.best_stream(AVMEDIA_TYPE_AUDIO);
  if (stream_ < 0) throw MediaError("no audio stream in " + src.describe());
  st_ = fmt->streams[stream_];
  for (unsigned i = 0; i < fmt->nb_streams; ++i) {
    if (static_cast<int>(i) != stream_) fmt->streams[i]->discard = AVDISCARD_ALL;
  }
  if (fmt->start_time != AV_NOPTS_VALUE) start_ = pts_to_ticks(fmt->start_time, AVRational{1, AV_TIME_BASE});
  if (fmt->duration != AV_NOPTS_VALUE && fmt->duration > 0) duration_ = pts_to_ticks(fmt->duration, AVRational{1, AV_TIME_BASE});

  const AVCodec* codec = avcodec_find_decoder(st_->codecpar->codec_id);
  if (!codec) throw MediaError(std::string("no decoder for ") + avcodec_get_name(st_->codecpar->codec_id));
  ctx_.reset(avcodec_alloc_context3(codec));
  if (!ctx_) throw MediaError("out of memory (codec)");
  check(avcodec_parameters_to_context(ctx_.get(), st_->codecpar), "codec parameters");
  ctx_->pkt_timebase = st_->time_base;
  check(avcodec_open2(ctx_.get(), codec, nullptr), "cannot open audio decoder");
  pkt_ = make_packet();
  frame_ = make_frame();
  seek(0);
}

AudioDecoder::~AudioDecoder() {
  if (swr_) swr_free(&swr_);
}

void AudioDecoder::seek(Ticks t) {
  t = std::max<Ticks>(0, t);
  const int64_t ts = ticks_to_pts(t + start_, st_->time_base);
  if (av_seek_frame(demux_.fmt(), stream_, ts, AVSEEK_FLAG_BACKWARD) < 0) {
    avformat_seek_file(demux_.fmt(), stream_, INT64_MIN, ts, ts, 0);
  }
  avcodec_flush_buffers(ctx_.get());
  if (swr_) swr_free(&swr_);  // drop resampler history
  fifo_.clear();
  fifo_pos_ = 0;
  emitted_ = 0;
  read_frames_ = 0;
  base_ = t;
  aligned_ = false;
  eof_sent_ = false;
  eof_ = false;
}

Ticks AudioDecoder::position() const {
  return base_ + mul_div(read_frames_, kTicksPerSecond, rate_, Rounding::Nearest);
}

void AudioDecoder::append(const float* data, size_t frames, Ticks chunk_time) {
  const size_t ch = static_cast<size_t>(channels_);
  const Ticks expected = base_ + mul_div(emitted_, kTicksPerSecond, rate_, Rounding::Nearest);
  int64_t skip = 0;
  int64_t silence = 0;
  const Ticks tolerance = aligned_ ? kTicksPerSecond / 25 : 0;  // 40 ms once running, exact at a seek
  const Ticks diff = chunk_time - expected;
  if (diff > tolerance) silence = mul_div(diff, rate_, kTicksPerSecond, Rounding::Nearest);
  if (diff < -tolerance) skip = mul_div(-diff, rate_, kTicksPerSecond, Rounding::Nearest);
  aligned_ = true;
  if (skip >= static_cast<int64_t>(frames)) return;
  if (silence > 0) {
    // Cap pathological gaps (broken timestamps) at 10 s of silence.
    silence = std::min<int64_t>(silence, static_cast<int64_t>(rate_) * 10);
    fifo_.insert(fifo_.end(), static_cast<size_t>(silence) * ch, 0.0f);
    emitted_ += silence;
  }
  const float* begin = data + static_cast<size_t>(skip) * ch;
  const float* end = data + frames * ch;
  fifo_.insert(fifo_.end(), begin, end);
  emitted_ += static_cast<int64_t>(frames) - skip;
}

bool AudioDecoder::decode_more() {
  for (;;) {
    const int r = avcodec_receive_frame(ctx_.get(), frame_.get());
    if (r == 0) {
      AVFrame* f = frame_.get();
      if (!swr_) {
        AVChannelLayout out_layout;
        av_channel_layout_default(&out_layout, channels_);
        AVChannelLayout in_layout;
        if (f->ch_layout.nb_channels > 0) {
          av_channel_layout_copy(&in_layout, &f->ch_layout);
        } else {
          av_channel_layout_default(&in_layout, ctx_->ch_layout.nb_channels > 0 ? ctx_->ch_layout.nb_channels : 2);
        }
        const int err = swr_alloc_set_opts2(&swr_, &out_layout, AV_SAMPLE_FMT_FLT, rate_, &in_layout,
                                            static_cast<AVSampleFormat>(f->format), f->sample_rate, 0, nullptr);
        av_channel_layout_uninit(&in_layout);
        av_channel_layout_uninit(&out_layout);
        check(err, "audio resampler");
        check(swr_init(swr_), "audio resampler init");
      }
      const int max_out = swr_get_out_samples(swr_, f->nb_samples);
      convert_buf_.resize(static_cast<size_t>(std::max(0, max_out)) * channels_);
      auto* out = reinterpret_cast<uint8_t*>(convert_buf_.data());
      const int n = swr_convert(swr_, &out, max_out, const_cast<const uint8_t**>(f->extended_data), f->nb_samples);
      check(n, "audio resample");
      int64_t ts = f->best_effort_timestamp;
      if (ts == AV_NOPTS_VALUE) ts = f->pts;
      const Ticks chunk = ts == AV_NOPTS_VALUE ? base_ + mul_div(emitted_, kTicksPerSecond, rate_, Rounding::Nearest)
                                               : pts_to_ticks(ts, st_->time_base) - start_;
      av_frame_unref(f);
      if (n > 0) append(convert_buf_.data(), static_cast<size_t>(n), chunk);
      return true;
    }
    if (r == AVERROR_EOF) return false;
    if (r != AVERROR(EAGAIN)) throw MediaError("audio decode: " + av_error_string(r));
    if (eof_sent_) return false;
    const int rr = av_read_frame(demux_.fmt(), pkt_.get());
    if (rr == AVERROR_EOF || (rr < 0 && avio_feof(demux_.fmt()->pb))) {
      avcodec_send_packet(ctx_.get(), nullptr);
      eof_sent_ = true;
      continue;
    }
    check(rr, "read");
    if (pkt_->stream_index == stream_) avcodec_send_packet(ctx_.get(), pkt_.get());  // damaged packets are skipped
    av_packet_unref(pkt_.get());
  }
}

size_t AudioDecoder::read(float* dst, size_t frames) {
  const size_t ch = static_cast<size_t>(channels_);
  size_t done = 0;
  while (done < frames) {
    const size_t available = (fifo_.size() - fifo_pos_ * ch) / ch;
    if (available == 0) {
      if (eof_ || !decode_more()) {
        eof_ = true;
        break;
      }
      continue;
    }
    const size_t n = std::min(available, frames - done);
    std::memcpy(dst + done * ch, fifo_.data() + fifo_pos_ * ch, n * ch * sizeof(float));
    fifo_pos_ += n;
    done += n;
    if (fifo_pos_ * ch == fifo_.size()) {
      fifo_.clear();
      fifo_pos_ = 0;
    } else if (fifo_pos_ > 1 << 16) {
      fifo_.erase(fifo_.begin(), fifo_.begin() + static_cast<std::ptrdiff_t>(fifo_pos_ * ch));
      fifo_pos_ = 0;
    }
  }
  read_frames_ += static_cast<int64_t>(done);
  return done;
}

std::vector<float> compute_peaks(const Source& src, int buckets_per_second, const volatile int32_t* cancel,
                                 volatile int32_t* progress) {
  if (buckets_per_second <= 0 || buckets_per_second > 1000) throw MediaError("buckets per second must be 1..1000");
  // A low working rate keeps this fast on 2-hour files; peaks do not need more.
  const int rate = buckets_per_second <= 100 ? 8000 : 48000;
  AudioDecoder dec(src, rate, 1);
  const int64_t per_bucket = std::max<int64_t>(1, rate / buckets_per_second);
  const Ticks dur = dec.duration();
  std::vector<float> peaks;
  if (dur > 0) peaks.reserve(static_cast<size_t>(mul_div(dur, buckets_per_second, kTicksPerSecond, Rounding::Up) * 2 + 2));
  std::vector<float> buf(static_cast<size_t>(rate));
  float lo = 0.0f, hi = 0.0f;
  int64_t in_bucket = 0;
  for (;;) {
    if (cancel && *cancel) break;
    const size_t n = dec.read(buf.data(), buf.size());
    for (size_t i = 0; i < n; ++i) {
      const float v = buf[i];
      if (in_bucket == 0) {
        lo = hi = v;
      } else {
        lo = std::min(lo, v);
        hi = std::max(hi, v);
      }
      if (++in_bucket == per_bucket) {
        peaks.push_back(lo);
        peaks.push_back(hi);
        in_bucket = 0;
      }
    }
    if (progress && dur > 0) *progress = static_cast<int32_t>(std::min<Ticks>(1000, mul_div(dec.position(), 1000, dur, Rounding::Down)));
    if (n < buf.size()) break;
  }
  if (in_bucket > 0) {
    peaks.push_back(lo);
    peaks.push_back(hi);
  }
  if (progress) *progress = 1000;
  return peaks;
}

}  // namespace cutlab::media
