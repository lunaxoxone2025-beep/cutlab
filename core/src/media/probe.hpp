// Media inspection (internal header).
#pragma once

#include <string>

#include "cutlab/time.hpp"
#include "demuxer.hpp"

namespace cutlab::media {

struct VideoStreamInfo {
  bool present = false;
  std::string codec;
  int width = 0;   // display size, rotation applied
  int height = 0;
  int coded_width = 0;
  int coded_height = 0;
  int rotation = 0;
  Rational frame_rate{0, 1};      // average rate
  Rational base_frame_rate{0, 1}; // lowest rate that represents all timestamps
  bool variable_frame_rate = false;
  int64_t frame_count = 0;        // 0 = unknown
  std::string pixel_format;
  int bit_depth = 8;
  bool still_image = false;
};

struct AudioStreamInfo {
  bool present = false;
  std::string codec;
  int sample_rate = 0;
  int channels = 0;
  std::string channel_layout;
};

struct ProbeResult {
  std::string container;
  Ticks duration = 0;      // 0 for still images
  Ticks start_time = 0;
  int64_t bit_rate = 0;
  int64_t size_bytes = -1;
  VideoStreamInfo video;
  AudioStreamInfo audio;

  std::string to_json() const;
};

ProbeResult probe(const Source& src);

}  // namespace cutlab::media
