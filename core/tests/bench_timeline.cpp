// Timeline playback measurements (not a pass/fail test):
//   cutlab_bench_timeline <media-dir> [real-size-dir]
// Prints CPU use, frames shown/dropped, A/V lateness, memory, and the cost
// of mixing many audio tracks. Uses the null audio device (steady clock).
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <sys/resource.h>
#endif

#include "cutlab/cutlab_core.h"

namespace {

constexpr int64_t SEC = 705600000;

double cpu_seconds() {
#ifndef _WIN32
  rusage u{};
  getrusage(RUSAGE_SELF, &u);
  return static_cast<double>(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + static_cast<double>(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6;
#else
  FILETIME created, exited, kernel, user;
  if (!GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user)) return 0.0;
  auto secs = [](FILETIME f) { return static_cast<double>((static_cast<unsigned long long>(f.dwHighDateTime) << 32) | f.dwLowDateTime) / 1e7; };
  return secs(kernel) + secs(user);
#endif
}

std::string clip(const std::string& file, int64_t start, int64_t dur, int64_t in) {
  return "clip c" + std::to_string(start) + " " + std::to_string(start) + " " + std::to_string(dur) + " " + std::to_string(in) +
         " 1 0 0 1 0 1 " + file + "\n";
}

std::string stat(const char* json, const char* key) {
  const std::string k = std::string("\"") + key + "\":";
  const char* p = std::strstr(json, k.c_str());
  if (!p) return "?";
  p += k.size();
  const char* e = p;
  while (*e && *e != ',' && *e != '}') ++e;
  return std::string(p, e);
}

void play_bench(const char* name, const std::string& plan, int seconds, int box) {
  cutlab_timeline* t = nullptr;
  if (cutlab_timeline_open(box, box, CUTLAB_PLAYER_NULL_AUDIO, &t) != CUTLAB_OK) return;
  if (cutlab_timeline_set_plan(t, plan.c_str()) != CUTLAB_OK) {
    std::printf("%-34s plan error: %s\n", name, cutlab_last_error());
    cutlab_timeline_close(t);
    return;
  }
  std::vector<uint8_t> buf(static_cast<size_t>(box) * box * 4);
  uint64_t serial = 0;
  int32_t w = 0, h = 0;
  int64_t pts = 0;
  // Let the first picture arrive, then measure steady playback.
  for (int i = 0; i < 200 && !cutlab_timeline_frame(t, &serial, buf.data(), static_cast<int64_t>(buf.size()), &w, &h, &pts); ++i) {
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  const double c0 = cpu_seconds();
  const auto w0 = std::chrono::steady_clock::now();
  cutlab_timeline_play(t);
  const auto end = w0 + std::chrono::seconds(seconds);
  while (std::chrono::steady_clock::now() < end && cutlab_timeline_playing(t)) {
    cutlab_timeline_frame(t, &serial, buf.data(), static_cast<int64_t>(buf.size()), &w, &h, &pts);
    std::this_thread::sleep_for(std::chrono::milliseconds(4));  // ~240 Hz polling (screen refresh)
  }
  const double wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - w0).count();
  const double cpu = cpu_seconds() - c0;
  char* json = nullptr;
  cutlab_timeline_stats(t, &json);
  std::printf("%-34s %5.0f%% CPU  shown %-5s dropped %-5s late avg %-6.6s ms max %-6.6s ms  rss %s KiB  %s\n", name, cpu / wall * 100.0,
              stat(json, "framesShown").c_str(), stat(json, "framesDropped").c_str(), stat(json, "videoLateAvgMs").c_str(),
              stat(json, "videoLateMaxMs").c_str(), stat(json, "rssKiB").c_str(), stat(json, "decoder").c_str());
  cutlab_free(json);
  cutlab_timeline_close(t);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s <test-media-dir> [real-size-media-dir]\n", argv[0]);
    return 2;
  }
  const std::string m = argv[1];
  const std::string r = argc > 2 ? argv[2] : "";
  std::printf("CPUs: %u\n", std::thread::hardware_concurrency());

  // Mixing cost: N tracks of sound, 60 s rendered offline.
  for (const int tracks : {1, 4, 8, 16}) {
    std::string plan = "cutlab-timeline 1\n";
    for (int i = 0; i < tracks; ++i) {
      plan += "track a" + std::to_string(i) + " audio 0 0 0 0.5\n";
      const std::string file = m + (i % 2 ? "/tone440.m4a" : "/tone1k.wav");
      for (int k = 0; k < 10; ++k) plan += clip(file, k * 6 * SEC, 6 * SEC, 0).replace(5, 1, "t" + std::to_string(i) + "_");
    }
    cutlab_timeline* t = nullptr;
    cutlab_timeline_open(320, 320, CUTLAB_PLAYER_NULL_AUDIO, &t);
    cutlab_timeline_set_plan(t, plan.c_str());
    std::vector<float> buf(4800 * 2);
    const auto t0 = std::chrono::steady_clock::now();
    for (int b = 0; b < 600; ++b) cutlab_timeline_render_audio(t, static_cast<int64_t>(b) * SEC / 10, 4800, buf.data(), nullptr, 0);
    const double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    std::printf("mix %2d tracks x 60 s: %.3f s  (%.0fx real time, %.2f%% of one CPU)\n", tracks, s, 60.0 / s, s / 60.0 * 100.0);
    cutlab_timeline_close(t);
  }

  // Playback.
  play_bench("2 clips 60 fps (small)", "cutlab-timeline 1\ntrack v video 0 0 0 1\n" + clip(m + "/gray60.mp4", 0, 4 * SEC, 0) +
                                           clip(m + "/gray60.mp4", 4 * SEC, 4 * SEC, 2 * SEC), 6, 1280);
  play_bench("120 fps source", "cutlab-timeline 1\ntrack v video 0 0 0 1\n" + clip(m + "/gray120.mkv", 0, 5 * SEC, 0), 4, 1280);
  play_bench("2-hour file (24 fps tiny frames)", "cutlab-timeline 1\ntrack v video 0 0 0 1\n" + clip(m + "/long2h.mp4", 0, 7200 * SEC, 0), 3, 1280);
  if (!r.empty()) {
    const std::string mix = "track a audio 0 0 0 1\n" + clip(m + "/tone1k.wav", 0, 6 * SEC, 0);
    play_bench("1080p30 H.264 + music, 720p preview", "cutlab-timeline 1\ntrack v video 0 0 0 1\n" + clip(r + "/h264_1080p30.mp4", 0, 6 * SEC, 0) + mix, 5, 1280);
    play_bench("1080p60 H.264, 720p preview", "cutlab-timeline 1\ntrack v video 0 0 0 1\n" + clip(r + "/h264_1080p60.mp4", 0, 6 * SEC, 0), 5, 1280);
    play_bench("1080p60 H.264, 1080p preview", "cutlab-timeline 1\ntrack v video 0 0 0 1\n" + clip(r + "/h264_1080p60.mp4", 0, 6 * SEC, 0), 5, 1920);
    play_bench("1080p60 HEVC, 720p preview", "cutlab-timeline 1\ntrack v video 0 0 0 1\n" + clip(r + "/hevc_1080p60.mp4", 0, 4 * SEC, 0), 4, 1280);
    play_bench("4K HEVC 10-bit, 720p preview", "cutlab-timeline 1\ntrack v video 0 0 0 1\n" + clip(r + "/hevc10_4k30.mp4", 0, 2 * SEC, 0), 2, 1280);
    play_bench("cuts every 1 s (1080p60, 2 files)", "cutlab-timeline 1\ntrack v video 0 0 0 1\n" + clip(r + "/h264_1080p60.mp4", 0, SEC, 0) +
                                                        clip(r + "/hevc_1080p60.mp4", SEC, SEC, SEC) + clip(r + "/h264_1080p60.mp4", 2 * SEC, SEC, 3 * SEC) +
                                                        clip(r + "/hevc_1080p60.mp4", 3 * SEC, SEC, 2 * SEC),
               4, 1280);
  }
  return 0;
}
