// Audio decoding to interleaved float at a fixed rate (internal header).
#pragma once

#include <cstddef>
#include <vector>

#include "demuxer.hpp"

namespace cutlab::media {

/// Decodes the best audio stream and resamples it to `out_rate` Hz,
/// `out_channels` channels, interleaved 32-bit float.
///
/// Sample-accurate timing: after seek(t) the first sample read is the one at
/// media time t (silence is inserted if the stream starts later). Gaps or
/// overlaps in the source timestamps larger than 40 ms are corrected with
/// silence/trimming so audio stays in sync with video over long recordings.
class AudioDecoder {
 public:
  AudioDecoder(const Source& src, int out_rate, int out_channels);
  ~AudioDecoder();
  AudioDecoder(const AudioDecoder&) = delete;
  AudioDecoder& operator=(const AudioDecoder&) = delete;

  void seek(Ticks t);

  /// Reads up to `frames` sample frames into dst (frames * channels floats).
  /// Returns the number read; fewer than requested only at end of stream.
  size_t read(float* dst, size_t frames);

  /// Media time of the next sample read() returns.
  Ticks position() const;
  Ticks duration() const { return duration_; }
  int rate() const { return rate_; }
  int channels() const { return channels_; }

 private:
  bool decode_more();
  void append(const float* data, size_t frames, Ticks chunk_time);

  Demuxer demux_;
  int stream_ = -1;
  AVStream* st_ = nullptr;
  CodecContextPtr ctx_;
  SwrContext* swr_ = nullptr;
  PacketPtr pkt_;
  FramePtr frame_;
  int rate_;
  int channels_;
  Ticks start_ = 0;
  Ticks duration_ = 0;
  bool eof_sent_ = false;
  bool eof_ = false;

  std::vector<float> fifo_;   // decoded samples not yet read
  size_t fifo_pos_ = 0;       // first unread frame in fifo_
  int64_t emitted_ = 0;       // frames produced since the last seek (read + queued)
  int64_t read_frames_ = 0;   // frames returned by read() since the last seek
  Ticks base_ = 0;            // media time of the first sample after the seek
  bool aligned_ = false;
  std::vector<float> convert_buf_;
};

/// Min/max peak pairs for a waveform: `buckets_per_second` buckets per
/// second of audio, mono. Reads the whole stream (in small chunks).
/// `cancel` (optional) stops early; `progress` receives 0..1000.
std::vector<float> compute_peaks(const Source& src, int buckets_per_second, const volatile int32_t* cancel,
                                 volatile int32_t* progress);

}  // namespace cutlab::media
