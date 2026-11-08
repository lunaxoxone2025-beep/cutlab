#include "demuxer.hpp"

#include <cerrno>
#include <cstdlib>
#include <cstring>

#ifndef _WIN32
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace cutlab::media {

std::string av_error_string(int err) {
  char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
  av_strerror(err, buf, sizeof buf);
  return buf;
}

int stream_rotation(const AVStream* st) {
  const AVPacketSideData* sd = av_packet_side_data_get(st->codecpar->coded_side_data, st->codecpar->nb_coded_side_data,
                                                       AV_PKT_DATA_DISPLAYMATRIX);
  if (!sd || sd->size < 9 * 4) return 0;
  const double angle = -av_display_rotation_get(reinterpret_cast<const int32_t*>(sd->data));
  int deg = static_cast<int>(angle >= 0 ? angle + 0.5 : angle - 0.5) % 360;
  if (deg < 0) deg += 360;
  // Snap to the nearest quarter turn.
  return ((deg + 45) / 90 % 4) * 90;
}

Source Source::parse(const std::string& uri) {
  Source s;
  if (uri.rfind("fd:", 0) == 0) {
    char* end = nullptr;
    const long v = std::strtol(uri.c_str() + 3, &end, 10);
    if (end == uri.c_str() + 3 || *end != '\0' || v < 0) throw MediaError("bad descriptor uri: " + uri);
    s.fd = static_cast<int>(v);
  } else {
    if (uri.empty()) throw MediaError("empty media path");
    s.path = uri;
  }
  return s;
}

// Positional reads over a private duplicate of the descriptor, so several
// decoders can read the same file concurrently without sharing an offset.
struct FdReader {
  int fd = -1;
  int64_t pos = 0;
  int64_t size = -1;
};

#ifndef _WIN32
static int fd_read(void* opaque, uint8_t* buf, int len) {
  auto* r = static_cast<FdReader*>(opaque);
  for (;;) {
    const ssize_t n = ::pread(r->fd, buf, static_cast<size_t>(len), static_cast<off_t>(r->pos));
    if (n < 0 && errno == EINTR) continue;
    if (n < 0) return AVERROR(errno);
    if (n == 0) return AVERROR_EOF;
    r->pos += n;
    return static_cast<int>(n);
  }
}

static int64_t fd_seek(void* opaque, int64_t offset, int whence) {
  auto* r = static_cast<FdReader*>(opaque);
  switch (whence & ~AVSEEK_FORCE) {
    case AVSEEK_SIZE: return r->size;
    case SEEK_SET: r->pos = offset; break;
    case SEEK_CUR: r->pos += offset; break;
    case SEEK_END:
      if (r->size < 0) return AVERROR(ENOSYS);
      r->pos = r->size + offset;
      break;
    default: return AVERROR(EINVAL);
  }
  return r->pos;
}
#endif

Demuxer::Demuxer(const Source& src) {
  fmt_ = avformat_alloc_context();
  if (!fmt_) throw MediaError("out of memory (format)");
  try {
    if (src.fd >= 0) {
#ifdef _WIN32
      throw MediaError("file descriptors are not supported on Windows");
#else
      reader_ = new FdReader();
      reader_->fd = ::dup(src.fd);
      if (reader_->fd < 0) throw MediaError(std::string("dup failed: ") + std::strerror(errno));
      struct stat st {};
      if (::fstat(reader_->fd, &st) == 0 && S_ISREG(st.st_mode)) reader_->size = st.st_size;
      constexpr int kBuf = 64 * 1024;
      auto* buf = static_cast<unsigned char*>(av_malloc(kBuf));
      if (!buf) throw MediaError("out of memory (io buffer)");
      avio_ = avio_alloc_context(buf, kBuf, 0, reader_, fd_read, nullptr, fd_seek);
      if (!avio_) {
        av_free(buf);
        throw MediaError("out of memory (io)");
      }
      if (reader_->size < 0) avio_->seekable = 0;
      fmt_->pb = avio_;
      fmt_->flags |= AVFMT_FLAG_CUSTOM_IO;
#endif
    }
    const std::string url = src.fd >= 0 ? std::string() : src.path;
    const int err = avformat_open_input(&fmt_, url.c_str(), nullptr, nullptr);  // frees fmt_ on failure
    if (err < 0) {
      fmt_ = nullptr;
      throw MediaError("cannot open " + src.describe() + ": " + av_error_string(err));
    }
    check(avformat_find_stream_info(fmt_, nullptr), "cannot read stream info");
  } catch (...) {
    cleanup();
    throw;
  }
}

Demuxer::~Demuxer() { cleanup(); }

void Demuxer::cleanup() {
  if (fmt_) {
    avformat_close_input(&fmt_);
    fmt_ = nullptr;
  }
  if (avio_) {
    av_freep(&avio_->buffer);
    avio_context_free(&avio_);
  }
#ifndef _WIN32
  if (reader_) {
    if (reader_->fd >= 0) ::close(reader_->fd);
    delete reader_;
    reader_ = nullptr;
  }
#endif
}

int Demuxer::best_stream(AVMediaType type) const {
  const int idx = av_find_best_stream(fmt_, type, -1, -1, nullptr, 0);
  if (idx < 0) return -1;
  // Cover art in audio files is a "video" stream with a single attached picture.
  if (type == AVMEDIA_TYPE_VIDEO && (fmt_->streams[idx]->disposition & AV_DISPOSITION_ATTACHED_PIC)) return -1;
  return idx;
}

}  // namespace cutlab::media
