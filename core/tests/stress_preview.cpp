// Preview-pipeline stress test: does through the C ABI what the app does
// when previewing media, many times and concurrently:
//   - open a player, play, poll frames into a fixed buffer (as Dart does),
//     scrub with fast and accurate seeks, pause, close — repeatedly;
//   - at the same time decode single frames (timeline monitor) and
//     thumbnails/waveforms (timeline) on other threads;
//   - open players for broken or unsupported files.
// Any crash, sanitizer report or leak is a failure. Usage:
//   cutlab_stress_preview <seconds-per-file> <file>...
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "cutlab/cutlab_core.h"

namespace {

constexpr int64_t kTps = 705600000;
std::atomic<int> g_failures{0};

void fail(const std::string& what) {
  std::fprintf(stderr, "FAIL: %s\n", what.c_str());
  ++g_failures;
}

int64_t duration_of(const std::string& uri, bool* has_video) {
  char* json = nullptr;
  *has_video = false;
  if (cutlab_media_probe(uri.c_str(), &json) != CUTLAB_OK) return 0;
  const char* d = std::strstr(json, "\"durationTicks\":");
  const int64_t v = d ? std::strtoll(d + 16, nullptr, 10) : 0;
  *has_video = std::strstr(json, "\"video\":{") != nullptr;
  cutlab_free(json);
  return v;
}

// One preview session like the source viewer: returns frames delivered.
int session(const std::string& uri, int flags, int max, int play_ms, unsigned seed) {
  cutlab_player* p = nullptr;
  if (cutlab_player_open(uri.c_str(), max, max, flags | CUTLAB_PLAYER_NULL_AUDIO, &p) != CUTLAB_OK) {
    fail("player_open " + uri + ": " + cutlab_last_error());
    return 0;
  }
  const int64_t dur = cutlab_player_duration(p);
  std::vector<uint8_t> buf(static_cast<size_t>(max) * max * 4);
  uint64_t serial = 0;
  int32_t w = 0, h = 0;
  int64_t pts = 0;
  int frames = 0;
  auto poll = [&] {
    if (cutlab_player_frame(p, &serial, buf.data(), static_cast<int64_t>(buf.size()), &w, &h, &pts)) {
      ++frames;
      if (w <= 0 || h <= 0 || w > max || h > max) fail("bad frame size " + std::to_string(w) + "x" + std::to_string(h));
    }
  };
  cutlab_player_play(p);
  const auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(play_ms);
  while (std::chrono::steady_clock::now() < until) {
    poll();
    std::this_thread::sleep_for(std::chrono::milliseconds(8));
  }
  // Scrub: a burst of fast seeks, then an accurate one, while playing and paused.
  for (int i = 0; i < 40; ++i) {
    seed = seed * 1103515245u + 12345u;
    const int64_t t = dur > 0 ? static_cast<int64_t>((seed >> 8) % 1000) * dur / 1000 : 0;
    cutlab_player_seek(p, t, i % 10 == 9 ? 1 : 0);
    if (i == 20) cutlab_player_pause(p);
    poll();
    std::this_thread::sleep_for(std::chrono::milliseconds(3));
  }
  cutlab_player_seek(p, dur, 1);  // the very end
  cutlab_player_play(p);          // restarts from 0
  for (int i = 0; i < 30; ++i) {
    poll();
    std::this_thread::sleep_for(std::chrono::milliseconds(8));
  }
  char* stats = nullptr;
  if (cutlab_player_stats(p, &stats) == CUTLAB_OK) cutlab_free(stats);
  cutlab_player_close(p);
  return frames;
}

void timeline_worker(const std::string& uri, int64_t dur, bool video, std::atomic<bool>& stop) {
  unsigned seed = 7;
  while (!stop) {
    seed = seed * 1103515245u + 12345u;
    const int64_t t = dur > 0 ? static_cast<int64_t>((seed >> 8) % 1000) * dur / 1000 : 0;
    uint8_t* px = nullptr;
    int32_t w = 0, h = 0;
    int64_t pts = 0;
    if (!video) {
      // Audio files have no picture: the call must fail cleanly.
      if (cutlab_media_frame(uri.c_str(), t, 640, 640, 1, &px, &w, &h, &pts) == CUTLAB_OK) fail("frame from audio file");
    } else if (cutlab_media_frame(uri.c_str(), t, 640, 640, (seed & 1) != 0, &px, &w, &h, &pts) == CUTLAB_OK) {
      cutlab_free(px);
    } else {
      fail("media_frame " + uri + ": " + cutlab_last_error());
    }
    int64_t ptsv[12];
    int32_t n = 0;
    if (cutlab_media_thumbnails(uri.c_str(), 12, 96, 54, &px, &w, &h, &n, ptsv) == CUTLAB_OK) cutlab_free(px);
    float* pairs = nullptr;
    int64_t np = 0;
    if (cutlab_media_peaks(uri.c_str(), 20, nullptr, nullptr, &pairs, &np) == CUTLAB_OK) cutlab_free(pairs);
  }
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s <seconds-per-file> <file>...\n", argv[0]);
    return 2;
  }
  const int secs = std::atoi(argv[1]);
  // Unplayable inputs must fail cleanly.
  for (const char* bad : {"/nonexistent/file.mp4", "fd:999999", "", "fd:abc"}) {
    cutlab_player* p = nullptr;
    if (cutlab_player_open(bad, 640, 640, CUTLAB_PLAYER_NULL_AUDIO, &p) == CUTLAB_OK) {
      fail(std::string("opened bad input ") + bad);
      cutlab_player_close(p);
    }
  }
  cutlab_player_close(nullptr);
  for (int i = 2; i < argc; ++i) {
    const std::string uri = argv[i];
    bool video = false;
    const int64_t dur = duration_of(uri, &video);
    std::printf("%s: duration %.2f s\n", uri.c_str(), static_cast<double>(dur) / kTps);
    std::atomic<bool> stop{false};
    std::thread t1(timeline_worker, uri, dur, video, std::ref(stop));
    std::thread t2(timeline_worker, uri, dur, video, std::ref(stop));
    const auto end = std::chrono::steady_clock::now() + std::chrono::seconds(secs);
    int sessions = 0, frames = 0;
    unsigned seed = 1;
    while (std::chrono::steady_clock::now() < end) {
      const int max = sessions % 3 == 0 ? 1280 : (sessions % 3 == 1 ? 1920 : 640);  // the preview quality choices
      const int flags = sessions % 2 ? CUTLAB_PLAYER_SOFTWARE_DECODE : 0;
      // Every other session closes almost immediately (open/close quickly).
      const int got = session(uri, flags, max, sessions % 2 ? 600 : 5, seed += 17);
      frames += got;
      if (video && sessions % 2 && got == 0) fail("no frames from " + uri);
      ++sessions;
    }
    stop = true;
    t1.join();
    t2.join();
    std::printf("  %d sessions, %d frames delivered\n", sessions, frames);
  }
  std::printf(g_failures ? "FAILED (%d)\n" : "OK\n", g_failures.load());
  return g_failures ? 1 : 0;
}
