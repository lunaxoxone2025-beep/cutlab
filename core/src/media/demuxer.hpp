// Opening media files (internal header).
#pragma once

#include <string>

#include "ffmpeg.hpp"

namespace cutlab::media {

/// Where media comes from: a file path, or "fd:<n>" for an already-open file
/// descriptor (Android content:// URIs). Descriptors are duplicated, never
/// closed or moved, so the caller keeps ownership of its own descriptor.
struct Source {
  std::string path;
  int fd = -1;

  static Source parse(const std::string& uri);
  std::string describe() const { return fd >= 0 ? "fd:" + std::to_string(fd) : path; }
};

/// Owns an AVFormatContext (and a custom I/O context for descriptors).
/// Reads go straight from the file in small blocks: nothing is loaded whole.
class Demuxer {
 public:
  explicit Demuxer(const Source& src);
  ~Demuxer();
  Demuxer(const Demuxer&) = delete;
  Demuxer& operator=(const Demuxer&) = delete;

  AVFormatContext* fmt() const { return fmt_; }

  /// Index of the best stream of `type`, or -1.
  int best_stream(AVMediaType type) const;

 private:
  void cleanup();

  AVFormatContext* fmt_ = nullptr;
  AVIOContext* avio_ = nullptr;
  struct FdReader* reader_ = nullptr;
};

}  // namespace cutlab::media
