// Timeline playback and mixer tests through the C ABI (as Flutter uses it).
// Needs the files from scripts/make_test_media.sh; set CUTLAB_TEST_MEDIA.
//
// Audio is checked by rendering the mix offline (exact, no device): tones of
// known amplitude give exact expected levels for volume, mute, solo, fades,
// several tracks and clip boundaries. Video is checked in real-time playback
// (null audio device = steady clock): every frame of gray60.mp4 encodes its
// index in its gray level, so each picture shown can be traced to the exact
// source frame and clip.
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <thread>
#include <vector>

#include "cutlab/cutlab_core.h"

namespace {

int g_checks = 0, g_failures = 0;
std::string g_dir;

#define CHECK(cond)                                                            \
  do {                                                                         \
    ++g_checks;                                                                \
    if (!(cond)) {                                                             \
      ++g_failures;                                                            \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
    }                                                                          \
  } while (0)

#define CHECK_NEAR(a, b, tol)                                                                                       \
  do {                                                                                                              \
    ++g_checks;                                                                                                     \
    const double va = (a), vb = (b);                                                                                \
    if (std::fabs(va - vb) > (tol)) {                                                                               \
      ++g_failures;                                                                                                 \
      std::fprintf(stderr, "%s:%d: CHECK_NEAR failed: %s=%g vs %s=%g (tol %g)\n", __FILE__, __LINE__, #a, va, #b, vb, \
                   static_cast<double>(tol));                                                                       \
    }                                                                                                               \
  } while (0)

constexpr int64_t TPS = 705600000;
constexpr int64_t SEC = TPS;
constexpr int64_t MS = TPS / 1000;

std::string path(const char* name) { return g_dir + "/" + name; }

struct Plan {
  std::string text = "cutlab-timeline 1\n";
  Plan& master(double v) {
    text += "master " + std::to_string(v) + "\n";
    return *this;
  }
  Plan& track(const char* id, const char* kind, bool muted = false, bool solo = false, bool hidden = false, double volume = 1.0) {
    text += std::string("track ") + id + " " + kind + " " + (muted ? "1" : "0") + " " + (solo ? "1" : "0") + " " + (hidden ? "1" : "0") +
            " " + std::to_string(volume) + "\n";
    return *this;
  }
  Plan& clip(const char* id, const char* file, int64_t start, int64_t dur, int64_t src_in, double volume = 1.0, int64_t fade_in = 0,
             int64_t fade_out = 0, bool audio = true, bool still = false) {
    text += std::string("clip ") + id + " " + std::to_string(start) + " " + std::to_string(dur) + " " + std::to_string(src_in) + " " +
            std::to_string(volume) + " " + std::to_string(fade_in) + " " + std::to_string(fade_out) + " " + (audio ? "1" : "0") + " " +
            (still ? "1" : "0") + " 1 " + path(file) + "\n";
    return *this;
  }
};

std::map<cutlab_timeline*, uint64_t> serials;

void close_tl(cutlab_timeline* t) {
  serials.erase(t);
  cutlab_timeline_close(t);
}

cutlab_timeline* open_tl(const Plan& p) {
  cutlab_timeline* t = nullptr;
  CHECK(cutlab_timeline_open(640, 640, CUTLAB_PLAYER_NULL_AUDIO, &t) == CUTLAB_OK);
  if (t) CHECK(cutlab_timeline_set_plan(t, p.text.c_str()) == CUTLAB_OK);
  return t;
}

// RMS over [from, from + len) of the left channel; peaks optional.
double rms(cutlab_timeline* t, int64_t from, int64_t len, std::vector<float>* peaks = nullptr) {
  const int frames = static_cast<int>(len * 48000 / TPS);
  std::vector<float> buf(static_cast<size_t>(frames) * 2);
  std::vector<float> p(8, 0.0f);
  CHECK(cutlab_timeline_render_audio(t, from, frames, buf.data(), p.data(), 8) == CUTLAB_OK);
  double s = 0;
  for (int i = 0; i < frames; ++i) s += static_cast<double>(buf[2 * i]) * buf[2 * i];
  if (peaks) *peaks = p;
  return std::sqrt(s / frames);
}

constexpr double kToneRms = 0.5 / 1.4142135623730951;  // a 0.5 amplitude sine

void test_plan_errors() {
  cutlab_timeline* t = nullptr;
  CHECK(cutlab_timeline_open(320, 320, CUTLAB_PLAYER_NULL_AUDIO, &t) == CUTLAB_OK);
  CHECK(cutlab_timeline_set_plan(t, "nonsense") == CUTLAB_ERR_INVALID_ARGUMENT);
  CHECK(cutlab_timeline_set_plan(t, "cutlab-timeline 1\ntrack v1 hologram 0 0 0 1\n") == CUTLAB_ERR_INVALID_ARGUMENT);
  CHECK(cutlab_timeline_set_plan(t, "cutlab-timeline 1\nclip c 0 1 0 1 0 0 1 0 1 /x.mp4\n") == CUTLAB_ERR_INVALID_ARGUMENT);
  CHECK(cutlab_timeline_set_plan(t, "cutlab-timeline 1\ntrack a audio 0 0 0 1\nclip c x 1 0 1 0 0 1 0 1 /x.mp4\n") ==
        CUTLAB_ERR_INVALID_ARGUMENT);
  CHECK(cutlab_timeline_set_plan(t, "cutlab-timeline 1\n") == CUTLAB_OK);  // empty timeline
  CHECK(cutlab_timeline_duration(t) == 0);
  cutlab_timeline_play(t);
  CHECK(cutlab_timeline_playing(t) == 0);  // nothing to play
  close_tl(t);
  cutlab_timeline_close(nullptr);
}

void test_mix_levels() {
  // One tone from 1 s to 4 s.
  cutlab_timeline* t = open_tl(Plan().track("a1", "audio").clip("c1", "tone1k.wav", 1 * SEC, 3 * SEC, 0));
  CHECK_NEAR(rms(t, 0, 500 * MS), 0.0, 1e-6);
  std::vector<float> peaks;
  CHECK_NEAR(rms(t, 2 * SEC, 100 * MS, &peaks), kToneRms, 0.01);
  CHECK_NEAR(peaks[0], 0.5, 0.02);  // track meter
  CHECK_NEAR(peaks[1], 0.5, 0.02);  // master meter
  CHECK_NEAR(rms(t, 4 * SEC + 10 * MS, 100 * MS), 0.0, 1e-6);  // after the clip
  close_tl(t);

  // Clip volume, track volume and master volume multiply.
  t = open_tl(Plan().master(0.5).track("a1", "audio", false, false, false, 2.0).clip("c1", "tone1k.wav", 0, 3 * SEC, 0, 0.5));
  CHECK_NEAR(rms(t, SEC, 100 * MS), kToneRms * 0.5 * 2.0 * 0.5, 0.01);
  close_tl(t);

  // Sample-accurate clip start: silent before 1 s, sound right after.
  t = open_tl(Plan().track("a1", "audio").clip("c1", "tone1k.wav", 1 * SEC, 2 * SEC, 250 * MS));
  std::vector<float> buf(400 * 2);
  CHECK(cutlab_timeline_render_audio(t, 1 * SEC - 200 * (TPS / 48000), 400, buf.data(), nullptr, 0) == CUTLAB_OK);
  double before = 0, after = 0;
  for (int i = 0; i < 200; ++i) before = std::max(before, static_cast<double>(std::fabs(buf[2 * i])));
  for (int i = 200; i < 230; ++i) after = std::max(after, static_cast<double>(std::fabs(buf[2 * i])));
  CHECK(before == 0.0);
  CHECK(after > 0.3);  // src_in 250 ms of a 1 kHz tone: the clip starts mid-wave
  close_tl(t);
}

void test_mute_solo_tracks() {
  auto plan = [](bool mute1, bool solo2) {
    return Plan()
        .track("a1", "audio", mute1, false)
        .clip("c1", "tone1k.wav", 0, 4 * SEC, 0)
        .track("a2", "audio", false, solo2)
        .clip("c2", "tone440.m4a", 0, 4 * SEC, 0);
  };
  // Two tracks at once: uncorrelated sines add in power.
  cutlab_timeline* t = open_tl(plan(false, false));
  std::vector<float> peaks;
  CHECK_NEAR(rms(t, SEC, 200 * MS, &peaks), std::sqrt(2.0) * kToneRms, 0.02);
  CHECK(peaks[0] > 0.45f && peaks[1] > 0.45f);
  CHECK(peaks[2] > 0.7f);  // master: both together
  close_tl(t);
  // Mute track 1: only the 440 Hz tone.
  t = open_tl(plan(true, false));
  CHECK_NEAR(rms(t, SEC, 200 * MS, &peaks), kToneRms, 0.02);
  CHECK(peaks[0] == 0.0f);
  close_tl(t);
  // Solo track 2: track 1 is silent although not muted.
  t = open_tl(plan(false, true));
  CHECK_NEAR(rms(t, SEC, 200 * MS, &peaks), kToneRms, 0.02);
  CHECK(peaks[0] == 0.0f);
  CHECK(peaks[1] > 0.45f);
  close_tl(t);
}

void test_fades() {
  // 3 s clip with 1 s fade in and 1 s fade out (linear).
  cutlab_timeline* t = open_tl(Plan().track("a1", "audio").clip("c1", "tone1k.wav", 0, 3 * SEC, 0, 1.0, SEC, SEC));
  CHECK_NEAR(rms(t, 250 * MS - 5 * MS, 10 * MS), kToneRms * 0.25, 0.01);
  CHECK_NEAR(rms(t, 500 * MS - 5 * MS, 10 * MS), kToneRms * 0.5, 0.01);
  CHECK_NEAR(rms(t, 1500 * MS, 10 * MS), kToneRms, 0.01);
  CHECK_NEAR(rms(t, 2750 * MS - 5 * MS, 10 * MS), kToneRms * 0.25, 0.01);
  CHECK(rms(t, 3 * SEC - 2 * MS, 2 * MS) < 0.01);
  close_tl(t);
}

void test_source_alignment_and_video_audio() {
  // gray60.mp4 has a 0.8 tone at 2.0–2.1 s of the source. Placed at 5 s with
  // in-point 1.5 s, the tone must sound at 5.5–5.6 s of the timeline.
  cutlab_timeline* t = open_tl(Plan().track("v1", "video").clip("v", "gray60.mp4", 5 * SEC, 2 * SEC, 1500 * MS));
  CHECK(rms(t, 5500 * MS + 10 * MS, 80 * MS) > 0.4);
  CHECK(rms(t, 5300 * MS, 150 * MS) < 0.02);
  CHECK(rms(t, 5650 * MS, 150 * MS) < 0.02);
  close_tl(t);
}

void test_bad_audio_sources() {
  // A photo, a missing file and a silent clip must not break the mix.
  cutlab_timeline* t = open_tl(Plan()
                                   .track("a1", "audio")
                                   .clip("img", "red.png", 0, 2 * SEC, 0)
                                   .track("a2", "audio")
                                   .clip("gone", "does-not-exist.wav", 0, 2 * SEC, 0)
                                   .track("a3", "audio")
                                   .clip("ok", "tone1k.wav", 0, 2 * SEC, 0));
  CHECK_NEAR(rms(t, SEC / 2, 100 * MS), kToneRms, 0.01);
  char* json = nullptr;
  CHECK(cutlab_timeline_stats(t, &json) == CUTLAB_OK);
  if (json) cutlab_free(json);
  close_tl(t);
}

void test_clipping() {
  cutlab_timeline* t = open_tl(Plan().master(2.0).track("a1", "audio", false, false, false, 2.0).clip("c1", "tone1k.wav", 0, SEC, 0, 2.0));
  std::vector<float> buf(4800 * 2);
  CHECK(cutlab_timeline_render_audio(t, 0, 4800, buf.data(), nullptr, 0) == CUTLAB_OK);
  float m = 0;
  for (float v : buf) m = std::max(m, std::fabs(v));
  CHECK(m <= 1.0f);
  close_tl(t);
}

void test_long_recording_mix() {
  const auto t0 = std::chrono::steady_clock::now();
  cutlab_timeline* t = open_tl(Plan().track("v1", "video").clip("v", "long2h.mp4", 0, 7200 * SEC, 0));
  // 10 s of mix at 1:59:00 (decoder seeks straight there).
  for (int i = 0; i < 10; ++i) rms(t, (7140 + i) * SEC, SEC);
  const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  std::printf("long recording: 10 s of mix at 1:59:00 in %.3f s\n", secs);
  CHECK(secs < 10.0);
  close_tl(t);
}

// ------------------------------------------------------------------ video

struct Shown {
  int64_t pts;
  int w, h;
  int gray;
};

// Plays (or waits paused) for `ms`, collecting every new picture. The
// serial is kept per timeline, as the app does: only new pictures count.
std::vector<Shown> collect(cutlab_timeline* t, int ms) {
  std::vector<Shown> out;
  std::vector<uint8_t> buf(640 * 640 * 4);
  uint64_t& serial = serials[t];
  const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
  while (std::chrono::steady_clock::now() < end) {
    int32_t w = 0, h = 0;
    int64_t pts = 0;
    if (cutlab_timeline_frame(t, &serial, buf.data(), static_cast<int64_t>(buf.size()), &w, &h, &pts)) {
      const int g = w > 0 ? buf[(static_cast<size_t>(h / 2) * w + w / 2) * 4] : -1;
      out.push_back({pts, w, h, g});
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(4));
  }
  return out;
}

// Plays until the end (or `max_ms`): real-time tests must not depend on how
// quickly a CI machine's (null) audio device starts.
std::vector<Shown> play_to_end(cutlab_timeline* t, int max_ms) {
  std::vector<Shown> all;
  const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(max_ms);
  do {
    auto part = collect(t, 100);
    all.insert(all.end(), part.begin(), part.end());
  } while (cutlab_timeline_playing(t) && std::chrono::steady_clock::now() < end);
  return all;
}

Shown frame_after_seek(cutlab_timeline* t, int64_t at) {
  cutlab_timeline_seek(t, at, 1);
  for (int i = 0; i < 200; ++i) {
    auto f = collect(t, 10);
    if (!f.empty()) return f.back();
  }
  return {-1, 0, 0, -2};
}

int expected_gray(int64_t src_ticks) { return static_cast<int>((src_ticks * 60 / TPS) % 256); }

void test_playback_two_clips() {
  // [0,1 s) source 0–1 s, then [1 s, 2 s) source 5–6 s (frames 300–359).
  cutlab_timeline* t =
      open_tl(Plan().track("v1", "video").clip("a", "gray60.mp4", 0, SEC, 0).clip("b", "gray60.mp4", SEC, SEC, 5 * SEC));
  CHECK(cutlab_timeline_duration(t) == 2 * SEC);
  cutlab_timeline_play(t);
  auto shown = play_to_end(t, 8000);
  CHECK(cutlab_timeline_playing(t) == 0);       // stopped at the end
  CHECK(cutlab_timeline_position(t) == 2 * SEC);
  int bad = 0, in_a = 0, in_b = 0;
  int64_t last = -1;
  for (const auto& s : shown) {
    if (s.pts <= last) ++bad;  // pictures always move forward
    last = s.pts;
    const int64_t src = s.pts < SEC ? s.pts : 5 * SEC + (s.pts - SEC);
    // A picture is shown from its own time on: compare with that frame.
    if (s.w > 0 && std::abs(s.gray - expected_gray(src + TPS / 120)) > 3) ++bad;
    (s.pts < SEC ? in_a : in_b)++;
  }
  std::printf("two clips: %zu pictures (%d from clip a, %d from clip b), %d wrong\n", shown.size(), in_a, in_b, bad);
  CHECK(bad == 0);
  CHECK(in_a > 10 && in_b > 10);
  char* json = nullptr;
  CHECK(cutlab_timeline_stats(t, &json) == CUTLAB_OK);
  if (json) {
    std::printf("stats: %s\n", json);
    CHECK(std::strstr(json, "\"clipTransitions\":0") == nullptr);
    cutlab_free(json);
  }
  // Seeking while paused shows the exact frame, in both clips.
  CHECK_NEAR(frame_after_seek(t, 500 * MS).gray, expected_gray(500 * MS), 3);
  CHECK_NEAR(frame_after_seek(t, 1500 * MS).gray, expected_gray(5500 * MS), 3);
  CHECK_NEAR(frame_after_seek(t, SEC).gray, expected_gray(5 * SEC), 3);  // exactly at the cut
  close_tl(t);
}

void test_gaps_overlaps_hidden_images() {
  cutlab_timeline* t = open_tl(Plan()
                                   .track("v1", "video")
                                   .clip("a", "gray60.mp4", 0, SEC, 0)
                                   .clip("b", "gray60.mp4", 2 * SEC, SEC, 2 * SEC)  // gap 1–2 s
                                   .track("v2", "video")
                                   .clip("top", "gray60.mp4", 250 * MS, 250 * MS, 8 * SEC)  // covers 0.25–0.5 s
                                   .track("img", "image")
                                   .clip("photo", "red.png", 2500 * MS, 250 * MS, 0, 1.0, 0, 0, false, true)
                                   .track("hid", "video", false, false, true)
                                   .clip("hidden", "gray60.mp4", 0, 3 * SEC, 3 * SEC));
  CHECK_NEAR(frame_after_seek(t, 100 * MS).gray, expected_gray(100 * MS), 3);
  CHECK_NEAR(frame_after_seek(t, 300 * MS).gray, expected_gray(8 * SEC + 50 * MS), 3);  // the upper clip
  CHECK_NEAR(frame_after_seek(t, 700 * MS).gray, expected_gray(700 * MS), 3);           // lower again
  const Shown gap = frame_after_seek(t, 1500 * MS);
  CHECK(gap.w == 0);  // black (hidden track not shown)
  CHECK_NEAR(frame_after_seek(t, 2200 * MS).gray, expected_gray(2200 * MS), 3);
  const Shown photo = frame_after_seek(t, 2600 * MS);
  CHECK(photo.w == 64 && photo.h == 48);
  // Continuous playback across all of it.
  cutlab_timeline_seek(t, 0, 1);
  cutlab_timeline_play(t);
  auto shown = play_to_end(t, 10000);
  bool saw_top = false, saw_black = false, saw_photo = false;
  for (const auto& s : shown) {
    if (s.pts >= 260 * MS && s.pts < 490 * MS && std::abs(s.gray - expected_gray(8 * SEC + (s.pts - 250 * MS) + TPS / 120)) <= 3) saw_top = true;
    if (s.pts >= SEC && s.pts < 2 * SEC && s.w == 0) saw_black = true;
    if (s.w == 64) saw_photo = true;
  }
  CHECK(saw_top && saw_black && saw_photo);
  close_tl(t);
}

void test_vfr_and_rotation() {
  cutlab_timeline* t = open_tl(Plan().track("v1", "video").clip("v", "vfr.mkv", 0, 2900 * MS, 0).clip("r", "rotated.mp4", 3 * SEC, SEC, 0));
  CHECK_NEAR(frame_after_seek(t, 1500 * MS + 10 * MS).gray, 75, 3);  // VFR: frame 75 at 1.5 s
  const Shown r = frame_after_seek(t, 3500 * MS);
  CHECK(r.h > r.w);  // phone portrait clip upright
  close_tl(t);
}

void test_start_stop_cycles_and_edits() {
  const Plan base = Plan().track("v1", "video").clip("a", "gray60.mp4", 0, 8 * SEC, 0).track("a1", "audio").clip("t", "tone1k.wav", 0, 6 * SEC, 0);
  cutlab_timeline* t = open_tl(base);
  unsigned seed = 3;
  for (int i = 0; i < 60; ++i) {
    seed = seed * 1103515245u + 12345u;
    cutlab_timeline_play(t);
    collect(t, 8 + static_cast<int>(seed % 20));
    cutlab_timeline_pause(t);
    if (i % 3 == 0) cutlab_timeline_seek(t, static_cast<int64_t>((seed >> 8) % 8000) * MS, (i % 2) != 0);
    if (i % 7 == 0) cutlab_timeline_set_plan(t, base.text.c_str());
  }
  // Paused means paused.
  cutlab_timeline_pause(t);
  const int64_t p0 = cutlab_timeline_position(t);
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  CHECK(cutlab_timeline_position(t) == p0);
  // Mix-only edit during playback keeps the picture going.
  cutlab_timeline_seek(t, SEC, 1);
  cutlab_timeline_play(t);
  collect(t, 300);
  const Plan quieter = Plan().track("v1", "video").clip("a", "gray60.mp4", 0, 8 * SEC, 0).track("a1", "audio", false, false, false, 0.3).clip("t", "tone1k.wav", 0, 6 * SEC, 0);
  CHECK(cutlab_timeline_set_plan(t, quieter.text.c_str()) == CUTLAB_OK);
  auto after = collect(t, 400);
  int black = 0;
  for (const auto& s : after) black += s.w == 0;
  CHECK(!after.empty());
  CHECK(black == 0);
  // The meters follow what is heard (steady clock without a device).
  // Valgrind runs one thread at a time, so the mix thread starves and the
  // null device plays gaps; the level value is only checked at normal speed.
  float lv[3] = {0, 0, 0};
  CHECK(cutlab_timeline_levels(t, lv, 3) == 3);
  // A busy machine can take longer than usual to play out the ~0.2 s mixed
  // before the change: wait up to 2 s for the quieter level to be heard.
  for (int i = 0; i < 100 && !(lv[1] > 0.1f && lv[1] < 0.2f) && cutlab_timeline_playing(t); ++i) {
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    cutlab_timeline_levels(t, lv, 3);
  }
  std::printf("levels while playing: video %.2f, tone %.2f, master %.2f\n", lv[0], lv[1], lv[2]);
  if (std::getenv("CUTLAB_UNDER_VALGRIND") == nullptr) CHECK(lv[1] > 0.1f && lv[1] < 0.2f);  // 0.5 × 0.3
  cutlab_timeline_pause(t);
  CHECK(cutlab_timeline_levels(t, lv, 3) == 3);
  CHECK(lv[1] == 0.0f);
  close_tl(t);
}

void test_long_recording_playback() {
  cutlab_timeline* t = open_tl(Plan().track("v1", "video").clip("v", "long2h.mp4", 0, 7200 * SEC, 0));
  const Shown s = frame_after_seek(t, 7190 * SEC);
  CHECK_NEAR(s.gray, static_cast<int>((7190LL * 30) % 256), 4);
  cutlab_timeline_seek(t, 7199 * SEC, 1);
  cutlab_timeline_play(t);
  auto shown = play_to_end(t, 6000);
  CHECK(!shown.empty());
  CHECK(cutlab_timeline_playing(t) == 0);  // reached the end (2:00:00)
  CHECK(cutlab_timeline_position(t) == 7200 * SEC);
  close_tl(t);
}

}  // namespace

int main() {
  const char* dir = std::getenv("CUTLAB_TEST_MEDIA");
  if (!dir) {
    std::fprintf(stderr, "CUTLAB_TEST_MEDIA is not set (run scripts/make_test_media.sh)\n");
    return 2;
  }
  g_dir = dir;
  test_plan_errors();
  test_mix_levels();
  test_mute_solo_tracks();
  test_fades();
  test_source_alignment_and_video_audio();
  test_bad_audio_sources();
  test_clipping();
  test_long_recording_mix();
  test_playback_two_clips();
  test_gaps_overlaps_hidden_images();
  test_vfr_and_rotation();
  test_start_stop_cycles_and_edits();
  test_long_recording_playback();
  std::printf("%d checks, %d failures\n", g_checks, g_failures);
  return g_failures ? 1 : 0;
}
