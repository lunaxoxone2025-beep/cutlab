// Media engine tests through the public C ABI (the same calls Flutter makes).
// Needs the files from scripts/make_test_media.sh; set CUTLAB_TEST_MEDIA.
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "cutlab/cutlab_core.h"

#ifndef _WIN32
#include <fcntl.h>
#include <unistd.h>
#endif

static int g_failures = 0;
static int g_checks = 0;
static std::string g_dir;

#define CHECK(cond)                                                                       \
  do {                                                                                    \
    ++g_checks;                                                                           \
    if (!(cond)) {                                                                        \
      ++g_failures;                                                                       \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s (%s)\n", __FILE__, __LINE__, #cond,   \
                   cutlab_last_error());                                                  \
    }                                                                                     \
  } while (0)

#define CHECK_NEAR(a, b, tol)                                                                        \
  do {                                                                                               \
    ++g_checks;                                                                                      \
    const double va = static_cast<double>(a), vb = static_cast<double>(b);                         \
    if (std::fabs(va - vb) > (tol)) {                                                                \
      ++g_failures;                                                                                  \
      std::fprintf(stderr, "%s:%d: CHECK_NEAR failed: %s=%g vs %s=%g (tol %g)\n", __FILE__, __LINE__, \
                   #a, va, #b, vb, static_cast<double>(tol));                                        \
    }                                                                                                \
  } while (0)

static const int64_t TPS = 705600000;

static std::string path(const char* name) { return g_dir + "/" + name; }
static bool exists(const char* name) {
  FILE* f = std::fopen(path(name).c_str(), "rb");
  if (f) std::fclose(f);
  return f != nullptr;
}
static int64_t frame_ticks(int64_t n, int64_t fps) { return n * TPS / fps; }

static double ms_since(std::chrono::steady_clock::time_point t0) {
  return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
}

// Crude JSON field readers (the engine writes compact, predictable JSON).
static std::string json_raw(const std::string& j, const std::string& key, size_t from = 0) {
  const size_t k = j.find("\"" + key + "\":", from);
  if (k == std::string::npos) return "";
  size_t v = k + key.size() + 3;
  size_t e = v;
  if (j[v] == '"') {
    e = j.find('"', v + 1);
    return j.substr(v + 1, e - v - 1);
  }
  while (e < j.size() && j[e] != ',' && j[e] != '}') ++e;
  return j.substr(v, e - v);
}
static int64_t json_int(const std::string& j, const std::string& key, size_t from = 0) {
  const std::string r = json_raw(j, key, from);
  return r.empty() ? -999 : std::strtoll(r.c_str(), nullptr, 10);
}

static std::string probe(const char* name) {
  char* json = nullptr;
  const cutlab_status s = cutlab_media_probe(path(name).c_str(), &json);
  CHECK(s == CUTLAB_OK);
  std::string out = json ? json : "";
  cutlab_free(json);
  return out;
}

// Gray level of the centre pixel = frame number mod 256 in the test videos.
static int frame_gray(const char* name, int64_t ticks, bool accurate, int64_t* pts = nullptr, int32_t* w = nullptr, int32_t* h = nullptr) {
  uint8_t* rgba = nullptr;
  int32_t fw = 0, fh = 0;
  int64_t fpts = -1;
  const cutlab_status s = cutlab_media_frame(path(name).c_str(), ticks, 0, 0, accurate ? 1 : 0, &rgba, &fw, &fh, &fpts);
  CHECK(s == CUTLAB_OK);
  if (s != CUTLAB_OK) return -1;
  const int g = rgba[(static_cast<size_t>(fh / 2) * fw + fw / 2) * 4];
  cutlab_free(rgba);
  if (pts) *pts = fpts;
  if (w) *w = fw;
  if (h) *h = fh;
  return g;
}

static void test_info_and_errors() {
  char* json = nullptr;
  CHECK(cutlab_engine_info(&json) == CUTLAB_OK);
  CHECK(json && std::string(json).find("\"mediaEngine\":true") != std::string::npos);
  std::printf("engine: %s\n", json ? json : "?");
  cutlab_free(json);

  json = nullptr;
  CHECK(cutlab_media_probe(path("does-not-exist.mp4").c_str(), &json) == CUTLAB_ERR_MEDIA);
  // Errors say what went wrong but never contain the file name or path (privacy).
  CHECK(std::string(cutlab_last_error()).find("does-not-exist") == std::string::npos);
  CHECK(std::string(cutlab_last_error()).find("mp4 file") != std::string::npos);
  CHECK(cutlab_media_probe(nullptr, &json) == CUTLAB_ERR_INVALID_ARGUMENT);
  CHECK(cutlab_media_probe(path("gray60.mp4").c_str(), nullptr) == CUTLAB_ERR_INVALID_ARGUMENT);
}

static void test_probe() {
  const std::string g = probe("gray60.mp4");
  CHECK_NEAR(json_int(g, "durationTicks"), 10 * TPS, TPS / 20);
  CHECK(json_int(g, "width") == 320 && json_int(g, "height") == 180);
  CHECK(json_int(g, "num", g.find("frameRate")) == 60 && json_int(g, "den", g.find("frameRate")) == 1);
  CHECK(json_raw(g, "variableFrameRate") == "false");
  CHECK(json_raw(g, "codec") == "h264");
  CHECK(json_int(g, "sampleRate") == 48000 && json_int(g, "channels") == 2);

  const std::string v = probe("vfr.mkv");
  CHECK(json_raw(v, "variableFrameRate") == "true");

  const std::string r = probe("rotated.mp4");
  // Stored landscape with a quarter-turn flag: shown portrait. Degrees are
  // the clockwise turn to apply (FFmpeg's convention), here 270.
  CHECK(json_int(r, "rotation") == 270);
  CHECK(json_int(r, "width") == 180 && json_int(r, "height") == 320);

  if (exists("hevc10.mp4")) {
    const std::string h = probe("hevc10.mp4");
    CHECK(json_raw(h, "codec") == "hevc");
    CHECK(json_int(h, "bitDepth") == 10);
  }

  const char* audio_file = exists("tone.mp3") ? "tone.mp3" : "tone.wav";
  const std::string a = probe(audio_file);
  CHECK(a.find("\"video\":null") != std::string::npos);
  CHECK(json_int(a, "sampleRate") == 44100);
  CHECK_NEAR(json_int(a, "durationTicks"), 3 * TPS, TPS / 10);

  const std::string p = probe("red.png");
  CHECK(json_raw(p, "stillImage") == "true");
  CHECK(json_int(p, "width") == 64);

  const std::string l = probe("long2h.mp4");
  CHECK_NEAR(json_int(l, "durationTicks"), 7200 * TPS, TPS / 10);
}

static void test_frame_accuracy() {
  // Frame N must come back for any time inside [N/fps, (N+1)/fps).
  for (const int64_t n : {0, 1, 2, 59, 60, 61, 137, 299, 300, 598}) {
    int64_t pts = -1;
    const int g = frame_gray("gray60.mp4", frame_ticks(n, 60) + frame_ticks(1, 60) / 2, true, &pts);
    CHECK_NEAR(g, n % 256, 3);
    CHECK(pts == frame_ticks(n, 60));
  }
  for (const int64_t n : {5, 120, 457, 599}) {
    int64_t pts = -1;
    CHECK_NEAR(frame_gray("gray120.mkv", frame_ticks(n, 120), true, &pts), n % 256, 3);
    // MKV stores timestamps in whole milliseconds: 120 fps frames are rounded.
    CHECK_NEAR(pts, frame_ticks(n, 120), TPS / 1000);
  }
  // Fast (scrub) seeks return the keyframe at or before the time: never
  // later, and never more than one GOP (60 frames) earlier.
  int64_t pts = -1;
  const int g = frame_gray("gray60.mp4", frame_ticks(137, 60), false, &pts);
  CHECK(pts <= frame_ticks(137, 60) && pts > frame_ticks(137 - 60, 60));
  CHECK_NEAR(g, (pts * 60 / TPS) % 256, 3);
}

static void test_variable_frame_rate() {
  // 60 fps for 1 s, then 30 fps: t = 1.5 s shows frame 60 + 15 = 75.
  CHECK_NEAR(frame_gray("vfr.mkv", TPS / 2, true), 30, 3);
  int64_t pts = -1;
  CHECK_NEAR(frame_gray("vfr.mkv", TPS * 3 / 2 + TPS / 100, true, &pts), 75, 3);
  CHECK(pts == TPS * 3 / 2);
}

static void test_rotation_and_images() {
  int32_t w = 0, h = 0;
  frame_gray("rotated.mp4", 0, true, nullptr, &w, &h);
  CHECK(w == 180 && h == 320);

  uint8_t* rgba = nullptr;
  int32_t iw = 0, ih = 0;
  CHECK(cutlab_media_frame(path("red.png").c_str(), 5 * TPS, 32, 32, 1, &rgba, &iw, &ih, nullptr) == CUTLAB_OK);
  CHECK(iw == 32 && ih == 24);
  if (rgba) CHECK(rgba[0] > 240 && rgba[1] < 16 && rgba[2] < 16 && rgba[3] == 255);
  cutlab_free(rgba);

  if (exists("hevc10.mp4")) CHECK_NEAR(frame_gray("hevc10.mp4", frame_ticks(45, 30), true), 45, 4);
}

static void test_long_recording() {
  // Seeking near the end of a 2-hour file must not decode from the start.
  const auto t0 = std::chrono::steady_clock::now();
  const int64_t n = 215955;  // 1:59:58.5 at 30 fps
  int64_t pts = -1;
  CHECK_NEAR(frame_gray("long2h.mp4", frame_ticks(n, 30), true, &pts), n % 256, 4);
  CHECK(pts == frame_ticks(n, 30));
  const double seek_ms = ms_since(t0);
  std::printf("2h file: accurate seek to 1:59:58.5 took %.0f ms\n", seek_ms);
  CHECK(seek_ms < 3000);

  const auto t1 = std::chrono::steady_clock::now();
  uint8_t* rgba = nullptr;
  int32_t w = 0, h = 0, count = 0;
  std::vector<int64_t> pts_list(24);
  CHECK(cutlab_media_thumbnails(path("long2h.mp4").c_str(), 24, 64, 64, &rgba, &w, &h, &count, pts_list.data()) == CUTLAB_OK);
  const double thumbs_ms = ms_since(t1);
  std::printf("2h file: 24 thumbnails in %.0f ms (%dx%d)\n", thumbs_ms, w, h);
  CHECK(count == 24);
  CHECK(w == 64 && h == 36);
  CHECK(thumbs_ms < 8000);
  for (int i = 1; i < count; ++i) CHECK(pts_list[i] > pts_list[i - 1]);
  CHECK(pts_list[count - 1] > 7000 * TPS);
  cutlab_free(rgba);

  const auto t2 = std::chrono::steady_clock::now();
  float* peaks = nullptr;
  int64_t pairs = 0;
  volatile int32_t progress = 0;
  CHECK(cutlab_media_peaks(path("long2h.mp4").c_str(), 10, nullptr, &progress, &peaks, &pairs) == CUTLAB_OK);
  std::printf("2h file: waveform (72k buckets) in %.0f ms\n", ms_since(t2));
  CHECK_NEAR(pairs, 72000, 20);
  CHECK(progress == 1000);
  cutlab_free(peaks);

  // Cancelling stops early.
  volatile int32_t cancel = 1;
  CHECK(cutlab_media_peaks(path("long2h.mp4").c_str(), 10, &cancel, nullptr, &peaks, &pairs) == CUTLAB_OK);
  CHECK(pairs < 100);
  cutlab_free(peaks);
}

static void test_audio_timing() {
  // The tone in gray60.mp4 spans 2.00 s - 2.10 s: peaks at 100 buckets/s must
  // place it within one bucket (10 ms) of where the video says it is.
  float* peaks = nullptr;
  int64_t pairs = 0;
  CHECK(cutlab_media_peaks(path("gray60.mp4").c_str(), 100, nullptr, nullptr, &peaks, &pairs) == CUTLAB_OK);
  CHECK_NEAR(pairs, 1000, 3);
  int first_loud = -1, last_loud = -1;
  for (int64_t i = 0; i < pairs; ++i) {
    const float amp = std::max(std::fabs(peaks[2 * i]), std::fabs(peaks[2 * i + 1]));
    if (amp > 0.4f) {
      if (first_loud < 0) first_loud = static_cast<int>(i);
      last_loud = static_cast<int>(i);
    }
  }
  std::printf("tone detected in buckets %d..%d (expected 200..209)\n", first_loud, last_loud);
  CHECK_NEAR(first_loud, 200, 1);
  CHECK_NEAR(last_loud, 209, 1);
  cutlab_free(peaks);
}

static void wait_frame(cutlab_player* p, uint64_t* serial, std::vector<uint8_t>& buf, int32_t* w, int32_t* h, int64_t* pts) {
  for (int i = 0; i < 300; ++i) {
    if (cutlab_player_frame(p, serial, buf.data(), static_cast<int64_t>(buf.size()), w, h, pts)) return;
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
}

static void test_player() {
  cutlab_player* p = nullptr;
  CHECK(cutlab_player_open(path("gray60.mp4").c_str(), 0, 0, CUTLAB_PLAYER_NULL_AUDIO | CUTLAB_PLAYER_SOFTWARE_DECODE, &p) == CUTLAB_OK);
  if (!p) return;
  CHECK_NEAR(cutlab_player_duration(p), 10 * TPS, TPS / 20);
  std::vector<uint8_t> buf(320 * 180 * 4);
  uint64_t serial = 0;
  int32_t w = 0, h = 0;
  int64_t pts = -1;

  wait_frame(p, &serial, buf, &w, &h, &pts);
  CHECK(serial > 0 && pts == 0 && w == 320 && h == 180);

  // Paused accurate seek shows exactly that frame.
  cutlab_player_seek(p, frame_ticks(137, 60), 1);
  wait_frame(p, &serial, buf, &w, &h, &pts);
  CHECK(pts == frame_ticks(137, 60));
  CHECK_NEAR(buf[(90 * 320 + 160) * 4], 137, 3);

  // Play for ~1 s: the audio clock advances and the frame follows it.
  cutlab_player_play(p);
  const auto t0 = std::chrono::steady_clock::now();
  int64_t max_lag = 0;
  int frames_seen = 0;
  while (ms_since(t0) < 1000) {
    if (cutlab_player_frame(p, &serial, buf.data(), static_cast<int64_t>(buf.size()), &w, &h, &pts)) {
      ++frames_seen;
      const int64_t lag = cutlab_player_position(p) - pts;
      if (frames_seen > 5) max_lag = std::max(max_lag, lag);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(4));
  }
  cutlab_player_pause(p);
  const int64_t pos = cutlab_player_position(p);
  std::printf("player: 1 s of playback -> position %.3f s, %d frames shown, max lag %.1f ms\n",
              static_cast<double>(pos - frame_ticks(137, 60)) / TPS, frames_seen, static_cast<double>(max_lag) * 1000 / TPS);
#ifdef _WIN32
  // miniaudio's null device (no sound card on CI) paces itself with coarse
  // Windows sleeps and consumes audio ~30% slower than real time; the clock
  // correctly follows the audio actually consumed. Real devices run at rate.
  CHECK(pos - frame_ticks(137, 60) > TPS / 2 && pos - frame_ticks(137, 60) < TPS * 5 / 4);
#else
  CHECK_NEAR(pos - frame_ticks(137, 60), TPS, TPS / 4);
#endif
  CHECK(frames_seen > 30);
  CHECK(max_lag < TPS / 20);  // shown frame within 50 ms of the clock
  CHECK(cutlab_player_playing(p) == 0);

  char* stats = nullptr;
  CHECK(cutlab_player_stats(p, &stats) == CUTLAB_OK);
  std::printf("player stats: %s\n", stats ? stats : "?");
  CHECK(stats && std::string(stats).find("\"hasAudio\":true") != std::string::npos);
  cutlab_free(stats);

  // A buffer that is too small reports the needed size and copies nothing.
  cutlab_player_seek(p, frame_ticks(10, 60), 1);
  uint8_t tiny[16];
  for (int i = 0; i < 300; ++i) {
    w = 0;
    if (cutlab_player_frame(p, &serial, tiny, sizeof tiny, &w, &h, &pts) == 0 && w == 320) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  CHECK(w == 320 && h == 180);
  cutlab_player_close(p);

  // Hardware decoding is attempted when allowed and silently falls back to
  // software when the machine has no usable decoder (CI runners).
  p = nullptr;
  CHECK(cutlab_player_open(path("gray60.mp4").c_str(), 0, 0, CUTLAB_PLAYER_NULL_AUDIO, &p) == CUTLAB_OK);
  if (p) {
    serial = 0;
    cutlab_player_seek(p, frame_ticks(301, 60), 1);
    wait_frame(p, &serial, buf, &w, &h, &pts);
    CHECK(pts == frame_ticks(301, 60));
    CHECK_NEAR(buf[(90 * 320 + 160) * 4], 301 % 256, 3);
    char* hw = nullptr;
    cutlab_player_stats(p, &hw);
    std::printf("hardware-allowed player: %s\n", hw ? hw : "?");
    cutlab_free(hw);
    cutlab_player_close(p);
  }

  // Video without audio runs on the steady clock.
  p = nullptr;
  CHECK(cutlab_player_open(path("gray120.mkv").c_str(), 160, 90, CUTLAB_PLAYER_SOFTWARE_DECODE, &p) == CUTLAB_OK);
  if (p) {
    cutlab_player_play(p);
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    CHECK_NEAR(cutlab_player_position(p), TPS / 2, TPS / 8);
    std::vector<uint8_t> small(160 * 90 * 4);
    serial = 0;
    wait_frame(p, &serial, small, &w, &h, &pts);
    CHECK(w == 160 && h == 90);
    cutlab_player_close(p);
  }

  // Audio-only files play too.
  p = nullptr;
  const char* audio_file = exists("tone.mp3") ? "tone.mp3" : "tone.wav";
  CHECK(cutlab_player_open(path(audio_file).c_str(), 0, 0, CUTLAB_PLAYER_NULL_AUDIO, &p) == CUTLAB_OK);
  if (p) {
    cutlab_player_play(p);
    std::this_thread::sleep_for(std::chrono::milliseconds(400));
    CHECK(cutlab_player_position(p) > TPS / 5);
    cutlab_player_close(p);
  }
}

static void test_file_descriptor() {
#ifndef _WIN32
  const int fd = ::open(path("gray60.mp4").c_str(), O_RDONLY);
  CHECK(fd >= 0);
  const std::string uri = "fd:" + std::to_string(fd);
  char* json = nullptr;
  CHECK(cutlab_media_probe(uri.c_str(), &json) == CUTLAB_OK);
  CHECK(json && std::string(json).find("\"width\":320") != std::string::npos);
  cutlab_free(json);
  uint8_t* rgba = nullptr;
  int32_t w = 0, h = 0;
  int64_t pts = 0;
  CHECK(cutlab_media_frame(uri.c_str(), frame_ticks(299, 60), 0, 0, 1, &rgba, &w, &h, &pts) == CUTLAB_OK);
  if (rgba) CHECK_NEAR(rgba[(90 * 320 + 160) * 4], 299 % 256, 3);
  cutlab_free(rgba);
  // The caller's descriptor is untouched and still usable.
  char byte = 0;
  CHECK(::pread(fd, &byte, 1, 0) == 1);
  cutlab_close_fd(fd);
  CHECK(cutlab_media_probe("fd:x", &json) == CUTLAB_ERR_MEDIA);
#endif
}

int main() {
  const char* dir = std::getenv("CUTLAB_TEST_MEDIA");
  if (!dir || !*dir) {
    std::fprintf(stderr, "CUTLAB_TEST_MEDIA is not set (run scripts/make_test_media.sh)\n");
    return 1;
  }
  g_dir = dir;
  test_info_and_errors();
  test_probe();
  test_frame_accuracy();
  test_variable_frame_rate();
  test_rotation_and_images();
  test_audio_timing();
  test_long_recording();
  test_player();
  test_file_descriptor();
  std::printf("%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
