// Export engine tests through the C ABI (as Flutter uses it).
// Needs the files from scripts/make_test_media.sh; set CUTLAB_TEST_MEDIA.
//
// Every exported file is checked by reading it back: its properties from
// the probe, pictures decoded at chosen times and compared with the source
// frame that should be there (gray60.mp4 encodes the frame number in its
// gray level), and its sound rendered through a timeline (exact levels of
// known tones, the position of a click for A/V sync).
//
//   cutlab_export_tests [--quick] [--long | --long-only]
//   cutlab_export_tests --bench <real-size-media-dir> [--hardware]
// --quick: fewer formats and sizes (valgrind); --long: a 2-hour export.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

#include "cutlab/cutlab_core.h"

namespace {

int g_checks = 0, g_failures = 0;
std::string g_dir, g_out;

#define CHECK(cond)                                                                 \
  do {                                                                              \
    ++g_checks;                                                                     \
    if (!(cond)) {                                                                  \
      ++g_failures;                                                                 \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
    }                                                                               \
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

constexpr int64_t SEC = 705600000;
constexpr int64_t MS = SEC / 1000;

std::string media(const char* name) { return g_dir + "/" + name; }
std::string out_path(const std::string& name) { return g_out + "/" + name; }

bool exists(const std::string& p) {
  std::ifstream f(p, std::ios::binary);
  return f.good();
}

// ------------------------------------------------------------ tiny JSON reads

double num(const std::string& json, const std::string& key, size_t from = 0) {
  const auto k = json.find("\"" + key + "\":", from);
  if (k == std::string::npos) return -1;
  return std::atof(json.c_str() + k + key.size() + 3);
}
std::string str(const std::string& json, const std::string& key, size_t from = 0) {
  const auto k = json.find("\"" + key + "\":\"", from);
  if (k == std::string::npos) return "";
  const auto b = k + key.size() + 4;
  return json.substr(b, json.find('"', b) - b);
}
size_t section(const std::string& json, const std::string& key) {
  const auto k = json.find("\"" + key + "\":");
  return k == std::string::npos ? std::string::npos : k;
}

// ------------------------------------------------------------ plans

struct Plan {
  std::string text = "cutlab-timeline 1\nhardware 0\n";
  Plan& master(double v) {
    text += "master " + std::to_string(v) + "\n";
    return *this;
  }
  Plan& track(const char* id, const char* kind, bool muted = false, bool solo = false, double volume = 1.0) {
    text += std::string("track ") + id + " " + kind + " " + (muted ? "1" : "0") + " " + (solo ? "1" : "0") + " 0 " + std::to_string(volume) + "\n";
    return *this;
  }
  Plan& clip(const char* id, const std::string& file, int64_t start, int64_t dur, int64_t in, double vol = 1.0, int64_t fin = 0,
             int64_t fout = 0, bool audio = true, bool still = false) {
    text += std::string("clip ") + id + " " + std::to_string(start) + " " + std::to_string(dur) + " " + std::to_string(in) + " " +
            std::to_string(vol) + " " + std::to_string(fin) + " " + std::to_string(fout) + " " + (audio ? "1" : "0") + " " +
            (still ? "1" : "0") + " 1 " + file + "\n";
    return *this;
  }
  Plan& overlay(int64_t start, int64_t dur, int x, int y, int w, int h, const std::string& file) {
    text += "overlay " + std::to_string(start) + " " + std::to_string(dur) + " " + std::to_string(x) + " " + std::to_string(y) + " " +
            std::to_string(w) + " " + std::to_string(h) + " " + file + "\n";
    return *this;
  }
  Plan& duration(int64_t d) {
    text += "duration " + std::to_string(d) + "\n";
    return *this;
  }
};

struct Settings {
  std::string path, container = "mp4", video = "h264", audio = "aac", speed = "fast", encoder;
  int w = 640, h = 360, quality = 75, bitrate = 0, hardware = 0;
  std::string fps = "30";
  std::string text() const {
    std::string t = "path " + path + "\ncontainer " + container + "\nvideo " + video + "\nsize " + std::to_string(w) + "x" + std::to_string(h) +
                    "\nfps " + fps + "\nquality " + std::to_string(quality) + "\nspeed " + speed + "\nhardware " + std::to_string(hardware) +
                    "\naudio " + audio + "\n";
    if (bitrate > 0) t += "bitrate " + std::to_string(bitrate) + "\n";
    if (!encoder.empty()) t += "encoder " + encoder + "\n";
    return t;
  }
};

std::string status_of(cutlab_export* e) {
  char* js = nullptr;
  if (cutlab_export_status(e, &js) != CUTLAB_OK || !js) return "";
  std::string s = js;
  cutlab_free(js);
  return s;
}

/// Runs an export to the end; returns the last status.
std::string run_export(const Plan& plan, const Settings& s, double* seconds = nullptr, int max_seconds = 900) {
  cutlab_export* e = nullptr;
  const auto t0 = std::chrono::steady_clock::now();
  if (cutlab_export_start(plan.text.c_str(), s.text().c_str(), &e) != CUTLAB_OK) {
    std::fprintf(stderr, "export_start failed: %s\n", cutlab_last_error());
    return "";
  }
  std::string st;
  for (;;) {
    st = status_of(e);
    const std::string state = str(st, "state");
    if (state == "done" || state == "failed" || state == "cancelled") break;
    if (std::chrono::steady_clock::now() - t0 > std::chrono::seconds(max_seconds)) {
      std::fprintf(stderr, "export timed out: %s\n", st.c_str());
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  }
  if (seconds) *seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  cutlab_export_close(e);
  if (str(st, "state") != "done") std::fprintf(stderr, "export of %s: %s\n", s.path.c_str(), st.c_str());
  return st;
}

std::string probe(const std::string& file) {
  char* js = nullptr;
  if (cutlab_media_probe(file.c_str(), &js) != CUTLAB_OK || !js) return "";
  std::string s = js;
  cutlab_free(js);
  return s;
}

struct Pic {
  std::vector<uint8_t> rgba;
  int w = 0, h = 0;
  int64_t pts = 0;
  bool ok = false;
  // Average of the red channel in a small square around (x, y), in 0..255.
  double at(int x, int y, int c = 0) const {
    double sum = 0;
    int n = 0;
    for (int dy = -2; dy <= 2; ++dy) {
      for (int dx = -2; dx <= 2; ++dx) {
        const int px = std::clamp(x + dx, 0, w - 1), py = std::clamp(y + dy, 0, h - 1);
        sum += rgba[(static_cast<size_t>(py) * w + px) * 4 + c];
        ++n;
      }
    }
    return sum / n;
  }
};

Pic frame(const std::string& file, int64_t t, int max = 0) {
  Pic p;
  uint8_t* rgba = nullptr;
  int32_t w = 0, h = 0;
  int64_t pts = 0;
  if (cutlab_media_frame(file.c_str(), t, max, max, 1, &rgba, &w, &h, &pts) == CUTLAB_OK && rgba) {
    p.rgba.assign(rgba, rgba + static_cast<size_t>(w) * h * 4);
    p.w = w;
    p.h = h;
    p.pts = pts;
    p.ok = true;
    cutlab_free(rgba);
  }
  return p;
}

/// The sound of a file, rendered through a timeline (48 kHz stereo).
std::vector<float> sound(const std::string& file, int64_t start, int frames) {
  std::vector<float> out(static_cast<size_t>(frames) * 2, 0.0f);
  cutlab_timeline* t = nullptr;
  if (cutlab_timeline_open(64, 64, 2, &t) != CUTLAB_OK) return out;
  const Plan p = Plan().track("a", "audio").clip("x", file, 0, 4 * 3600 * SEC, 0);
  cutlab_timeline_set_plan(t, p.text.c_str());
  cutlab_timeline_render_audio(t, start, frames, out.data(), nullptr, 0);
  cutlab_timeline_close(t);
  return out;
}

double rms(const std::vector<float>& s) {
  double sum = 0;
  for (const float v : s) sum += static_cast<double>(v) * v;
  return s.empty() ? 0 : std::sqrt(sum / s.size());
}

void write_rgba(const std::string& file, int w, int h, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
  std::ofstream f(file, std::ios::binary);
  for (int i = 0; i < w * h; ++i) {
    const char px[4] = {static_cast<char>(r), static_cast<char>(g), static_cast<char>(b), static_cast<char>(a)};
    f.write(px, 4);
  }
}

/// Exported files and what they must be, for the independent check with
/// ffprobe in CI (scripts/verify_exports.py): file|w|h|fps|frames|video|audio.
void record(const std::string& file, int w, int h, const std::string& fps, int64_t frames, const std::string& vcodec, const std::string& acodec) {
  std::ofstream m(g_out + "/exports.txt", std::ios::app);
  const auto slash = file.find_last_of("/\\");
  m << file.substr(slash == std::string::npos ? 0 : slash + 1) << '|' << w << '|' << h << '|' << fps << '|' << frames << '|' << vcodec << '|'
    << acodec << '\n';
}

bool g_quick = false;

// ------------------------------------------------------------ encoders

struct Enc {
  std::string codec, name;
  bool hardware = false;
};

std::vector<Enc> encoders() {
  std::vector<Enc> out;
  char* js = nullptr;
  if (cutlab_export_encoders(0, &js) != CUTLAB_OK || !js) return out;
  const std::string s = js;
  cutlab_free(js);
  size_t at = 0;
  while ((at = s.find('{', at)) != std::string::npos) {
    Enc e{str(s, "codec", at), str(s, "name", at), s.compare(s.find("\"hardware\":", at) + 11, 4, "true") == 0};
    out.push_back(e);
    ++at;
  }
  return out;
}

bool has_sw(const std::vector<Enc>& list, const std::string& codec) {
  return std::any_of(list.begin(), list.end(), [&](const Enc& e) { return e.codec == codec && !e.hardware; });
}

std::string g_codec = "h264";  // main codec for the timeline tests (best software one in the build)

// ------------------------------------------------------------ tests

void test_settings_rejected() {
  cutlab_export* e = nullptr;
  const Plan p = Plan().track("v", "video").clip("a", media("gray60.mp4"), 0, SEC, 0);
  Settings s;
  s.path = out_path("bad.webm");
  s.container = "webm";
  s.video = "h264";
  CHECK(cutlab_export_start(p.text.c_str(), s.text().c_str(), &e) == CUTLAB_ERR_INVALID_ARGUMENT);
  CHECK(e == nullptr);
  s.container = "mp4";
  s.w = 8;
  CHECK(cutlab_export_start(p.text.c_str(), s.text().c_str(), &e) == CUTLAB_ERR_INVALID_ARGUMENT);
  CHECK(cutlab_export_start("not a plan", Settings{out_path("x.mp4")}.text().c_str(), &e) == CUTLAB_ERR_INVALID_ARGUMENT);
  // An encoder that does not exist fails with a message.
  Settings s2;
  s2.path = out_path("missing.mp4");
  s2.encoder = "no_such_encoder";
  s2.video = g_codec;
  const std::string st = run_export(p, s2);
  CHECK(str(st, "state") == "failed");
  CHECK(str(st, "error").find("not available") != std::string::npos);
  CHECK(!exists(s2.path) && !exists(s2.path + ".part"));
}

// The whole timeline: two clips, a gap, a portrait clip covering on an upper
// track, a photo, a sound track with volume and fade, a title; letterboxed
// into 4:3.
void test_complete_timeline() {
  const std::string title = out_path("title.rgba");
  write_rgba(title, 100, 40, 255, 255, 255, 255);
  const Plan p = Plan()
                     .track("v1", "video")
                     .clip("a", media("gray60.mp4"), 0, 2 * SEC, 1 * SEC)        // source 1..3 s; its click (2.0 s) at 1.0 s
                     .clip("b", media("gray120.mkv"), 2500 * MS, 1500 * MS, 0, 1, 0, 0, false)
                     .track("v2", "video")
                     .clip("r", media("rotated.mp4"), 3 * SEC, 500 * MS, 0, 1, 0, 0, false)
                     .track("i1", "image")
                     .clip("p", media("red.png"), 4 * SEC, 500 * MS, 0, 1, 0, 0, false, true)
                     .track("a1", "audio", false, false, 0.5)
                     .clip("t", media("tone1k.wav"), 500 * MS, 2500 * MS, 0, 1.0, 250 * MS)
                     .overlay(1 * SEC, 1 * SEC, 20, 20, 100, 40, title);
  Settings s;
  s.path = out_path("complete.mp4");
  s.video = g_codec;
  s.w = 640;
  s.h = 480;
  s.fps = "30";
  s.quality = 90;
  double secs = 0;
  const std::string st = run_export(p, s, &secs);
  CHECK(str(st, "state") == "done");
  CHECK(num(st, "framesTotal") == 135);  // 4.5 s at 30 fps
  CHECK(num(st, "framesDone") == 135);
  CHECK(exists(s.path) && !exists(s.path + ".part"));
  std::printf("complete timeline: %s, %.2f s, %s\n", str(st, "encoder").c_str(), secs, st.c_str());
  record(s.path, 640, 480, "30", 135, g_codec, "aac");

  const std::string pr = probe(s.path);
  const size_t v = section(pr, "video");
  CHECK(num(pr, "width", v) == 640);
  CHECK(num(pr, "height", v) == 480);
  CHECK(num(pr, "num", v) / num(pr, "den", v) == 30.0);
  CHECK_NEAR(num(pr, "durationTicks") / SEC, 4.5, 0.05);
  const size_t a = section(pr, "audio");
  CHECK(a != std::string::npos && num(pr, "sampleRate", a) == 48000 && num(pr, "channels", a) == 2);
  std::printf("  probe: %s\n", pr.c_str());

  // Pictures: the exported frame matches the source frame (gray level).
  // 640x480 output, 16:9 source fills 640x360 at y = 60.
  auto src_gray = [&](const char* f, int64_t t) {
    const Pic sp = frame(media(f), t);
    return sp.ok ? sp.at(sp.w / 2, sp.h / 2) : -1.0;
  };
  for (const double sec : {0.0, 0.5, 1.2, 1.9}) {
    const int64_t t = static_cast<int64_t>(sec * SEC);
    const Pic o = frame(s.path, t);
    CHECK(o.ok && o.w == 640 && o.h == 480);
    if (!o.ok) continue;
    const double want = src_gray("gray60.mp4", t + SEC);
    CHECK_NEAR(o.at(320, 240), want, 6);
    CHECK(o.at(320, 20) < 24);   // letterbox bar, top
    CHECK(o.at(320, 460) < 24);  // bottom
  }
  {
    const Pic o = frame(s.path, 1500 * MS);  // the title
    CHECK(o.ok && o.at(60, 40) > 225 && o.at(60, 40, 2) > 225);
    const Pic before = frame(s.path, 500 * MS);
    CHECK(before.ok && before.at(60, 40) < 200);
  }
  {
    const Pic o = frame(s.path, 2250 * MS);  // gap: black
    CHECK(o.ok && o.at(320, 240) < 24);
  }
  {
    const Pic o = frame(s.path, 2800 * MS);  // clip b (120 fps source) at 0.3 s
    CHECK(o.ok);
    if (o.ok) CHECK_NEAR(o.at(320, 240), src_gray("gray120.mkv", 300 * MS), 6);
  }
  {
    const Pic o = frame(s.path, 3250 * MS);  // portrait clip over b: pillarboxed, upright
    CHECK(o.ok);
    if (o.ok) {
      CHECK(o.at(20, 240) < 24 && o.at(620, 240) < 24);
      CHECK_NEAR(o.at(320, 240), src_gray("rotated.mp4", 250 * MS), 8);
    }
  }
  {
    const Pic o = frame(s.path, 4250 * MS);  // the photo: red
    CHECK(o.ok && o.at(320, 240, 0) > 200 && o.at(320, 240, 1) < 60);
  }

  // Sound: tone 0.5 × track 0.5 = 0.25 peak (rms 0.177) from 0.5 s, faded in
  // over 0.25 s; the video's click (source 2.0 s) lands at 1.0 s; nothing
  // after the tone ends at 3.0 s.
  const auto quiet = sound(s.path, 200 * MS, 9600);
  CHECK(rms(quiet) < 0.01);
  const auto steady = sound(s.path, 1500 * MS, 9600);
  CHECK_NEAR(rms(steady), 0.25 / std::sqrt(2.0), 0.02);
  const auto fading = sound(s.path, 520 * MS, 2400);
  CHECK(rms(fading) < rms(steady) * 0.5);
  const auto after = sound(s.path, 3200 * MS, 9600);
  CHECK(rms(after) < 0.01);
  // A/V sync: the click starts at 1.0 s (the tone track is 0.25 peak).
  const auto around = sound(s.path, 900 * MS, 9600);  // 0.9 .. 1.1 s
  int first = -1;
  for (size_t i = 0; i < around.size(); i += 2) {
    if (std::fabs(around[i]) > 0.5) {
      first = static_cast<int>(i / 2);
      break;
    }
  }
  CHECK(first >= 0);
  const double click = 0.9 + first / 48000.0;
  std::printf("  sound: quiet %.4f steady %.4f fading %.4f after %.4f; click at %.4f s\n", rms(quiet), rms(steady), rms(fading), rms(after),
              click);
  CHECK_NEAR(click, 1.0, 0.003);
}

void test_mute_solo_master() {
  // Video sound muted, tone soloed... then muted: levels follow.
  auto level = [&](const Plan& p, const char* name) {
    Settings s;
    s.path = out_path(name);
    s.video = g_codec;
    s.w = 320;
    s.h = 180;
    const std::string st = run_export(p, s);
    CHECK(str(st, "state") == "done");
    return rms(sound(s.path, 500 * MS, 9600));
  };
  const double full = level(Plan().track("v", "video", true).clip("a", media("gray60.mp4"), 0, SEC, 0).track("t", "audio").clip("t", media("tone1k.wav"), 0, SEC, 0),
                            "mix_full.mp4");
  const double master = level(Plan().master(0.5).track("v", "video").clip("a", media("gray60.mp4"), 0, SEC, 0).track("t", "audio").clip("t", media("tone1k.wav"), 0, SEC, 0),
                              "mix_master.mp4");
  const double muted = level(Plan().track("v", "video").clip("a", media("gray60.mp4"), 0, SEC, 0).track("t", "audio", true).clip("t", media("tone1k.wav"), 0, SEC, 0),
                             "mix_muted.mp4");
  const double solo = level(Plan().track("v", "video", false, true).clip("a", media("gray60.mp4"), 0, SEC, 0).track("t", "audio").clip("t", media("tone1k.wav"), 0, SEC, 0),
                            "mix_solo.mp4");
  const double clipvol = level(Plan().track("v", "video", true).clip("a", media("gray60.mp4"), 0, SEC, 0).track("t", "audio").clip("t", media("tone1k.wav"), 0, SEC, 0, 0.25),
                               "mix_clipvol.mp4");
  std::printf("mix: full %.4f master %.4f muted %.4f solo-other %.4f clip 0.25 %.4f\n", full, master, muted, solo, clipvol);
  CHECK_NEAR(full, 0.5 / std::sqrt(2.0), 0.03);
  CHECK_NEAR(master, full / 2, 0.02);
  CHECK(muted < 0.01);  // the video's own sound is silent at 0.5 s
  CHECK(solo < 0.01);   // only the (silent there) video track is heard
  CHECK_NEAR(clipvol, full / 4, 0.01);
}

void test_formats(const std::vector<Enc>& encs) {
  const Plan p = Plan().track("v", "video").clip("a", media("gray60.mp4"), 0, 2 * SEC, 0).track("t", "audio").clip("t", media("tone1k.wav"), 0, 2 * SEC, 0);
  struct Case {
    const char* codec;
    const char* container;
    const char* audio;
    const char* probe_codec;
  };
  const Case cases[] = {{"h264", "mp4", "aac", "h264"},  {"hevc", "mp4", "aac", "hevc"},   {"vp9", "webm", "opus", "vp9"},
                        {"av1", "mp4", "aac", "av1"},    {"av1", "webm", "opus", "av1"},   {"mpeg4", "mp4", "aac", "mpeg4"},
                        {"h264", "mkv", "aac", "h264"},  {"hevc", "mov", "aac", "hevc"}};
  for (const auto& c : cases) {
    if (g_quick && std::string(c.codec) != g_codec) continue;
    if (!has_sw(encs, c.codec)) {
      std::printf("format %s/%s: no software encoder in this build, skipped\n", c.codec, c.container);
      continue;
    }
    const bool has_opus = has_sw(encs, "opus");
    if (std::string(c.audio) == "opus" && !has_opus) {
      std::printf("format %s/%s: no Opus encoder, skipped\n", c.codec, c.container);
      continue;
    }
    Settings s;
    s.path = out_path(std::string("fmt_") + c.codec + "." + c.container);
    s.container = c.container;
    s.video = c.codec;
    s.audio = c.audio;
    double secs = 0;
    const std::string st = run_export(p, s, &secs);
    CHECK(str(st, "state") == "done");
    const std::string pr = probe(s.path);
    const size_t v = section(pr, "video");
    const size_t a = section(pr, "audio");
    CHECK(str(pr, "codec", v) == c.probe_codec);
    CHECK(num(pr, "width", v) == 640 && num(pr, "height", v) == 360);
    CHECK(a != std::string::npos && str(pr, "codec", a) == (std::string(c.audio) == "opus" ? "opus" : "aac"));
    CHECK_NEAR(num(pr, "durationTicks") / SEC, 2.0, 0.06);
    const Pic o = frame(s.path, 1500 * MS);
    const Pic src = frame(media("gray60.mp4"), 1500 * MS);
    if (!o.ok && std::string(c.codec) == "av1") {
      // Builds without an AV1 decoder (Linux, the Android emulator engine):
      // the picture is checked by scripts/verify_exports.py instead.
      std::printf("format av1/%s: this build cannot decode AV1; picture checked by ffprobe/ffmpeg\n", c.container);
    } else {
      CHECK(o.ok && src.ok);
      if (o.ok && src.ok) CHECK_NEAR(o.at(320, 180), src.at(src.w / 2, src.h / 2), 8);
    }
    const double level = rms(sound(s.path, 1000 * MS, 9600));
    std::printf("format %s/%s: sound rms %.4f (expected %.4f)\n", c.codec, c.container, level, 0.5 / std::sqrt(2.0));
    CHECK_NEAR(level, 0.5 / std::sqrt(2.0), 0.03);
    record(s.path, 640, 360, "30", 60, c.probe_codec, std::string(c.audio) == "opus" ? "opus" : "aac");
    std::printf("format %s/%s: %s, %.2f s, %lld bytes\n", c.codec, c.container, str(st, "encoder").c_str(), secs,
                static_cast<long long>(num(st, "bytes")));
  }
}

void test_resolutions_and_rates() {
  const Plan p = Plan().track("v", "video").clip("a", media("gray120.mkv"), 0, 1 * SEC, 0);
  struct Case {
    int w, h;
    const char* fps;
    double rate;
  };
  const Case cases[] = {{854, 480, "24", 24},          {1280, 720, "60", 60},   {1920, 1080, "30", 30},     {2560, 1440, "30", 30},
                        {3840, 2160, "24", 24},        {1280, 720, "120", 120}, {1920, 1080, "30000/1001", 30000.0 / 1001}};
  for (const auto& c : cases) {
    if (g_quick && c.h > 720) continue;
    Settings s;
    s.path = out_path("res_" + std::to_string(c.h) + "_" + std::to_string(static_cast<int>(c.rate)) + ".mp4");
    s.video = g_codec;
    s.w = c.w;
    s.h = c.h;
    s.fps = c.fps;
    s.audio = "none";
    double secs = 0;
    const std::string st = run_export(p, s, &secs);
    CHECK(str(st, "state") == "done");
    const int64_t want_frames = static_cast<int64_t>(std::ceil(c.rate - 1e-9));
    CHECK(num(st, "framesDone") == want_frames);
    const std::string pr = probe(s.path);
    const size_t v = section(pr, "video");
    CHECK(num(pr, "width", v) == c.w && num(pr, "height", v) == c.h);
    CHECK_NEAR(num(pr, "num", v) / num(pr, "den", v), c.rate, 0.01);
    CHECK(section(pr, "audio") == std::string::npos || pr.find("\"audio\":null") != std::string::npos);
    // The last frame is there and is the source frame for its time.
    const int64_t last_t = static_cast<int64_t>((want_frames - 1) / c.rate * SEC);
    const Pic o = frame(s.path, last_t, 640);
    const Pic src = frame(media("gray120.mkv"), last_t);
    CHECK(o.ok && src.ok);
    if (o.ok && src.ok) CHECK_NEAR(o.at(o.w / 2, o.h / 2), src.at(src.w / 2, src.h / 2), 8);
    record(s.path, c.w, c.h, c.fps, want_frames, g_codec, "");
    std::printf("%dx%d @ %s: %.2f s (%.0f fps), %s\n", c.w, c.h, c.fps, secs, want_frames / std::max(secs, 1e-3), str(st, "encoder").c_str());
  }
}

void test_cancel_and_pause() {
  const Plan p = Plan().track("v", "video").clip("a", media("gray60.mp4"), 0, 10 * SEC, 0);
  Settings s;
  s.path = out_path("cancelled.mp4");
  s.video = g_codec;
  s.w = g_quick ? 640 : 1920;
  s.h = g_quick ? 360 : 1080;
  s.fps = "60";
  cutlab_export* e = nullptr;
  CHECK(cutlab_export_start(p.text.c_str(), s.text().c_str(), &e) == CUTLAB_OK);
  // Pause: no progress while paused.
  while (num(status_of(e), "framesDone") < 5 && str(status_of(e), "state") != "failed") std::this_thread::sleep_for(std::chrono::milliseconds(5));
  cutlab_export_pause(e, 1);
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  const double f0 = num(status_of(e), "framesDone");
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  const std::string paused = status_of(e);
  CHECK(num(paused, "framesDone") == f0);
  CHECK(paused.find("\"paused\":true") != std::string::npos);
  cutlab_export_pause(e, 0);
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  CHECK(num(status_of(e), "framesDone") > f0);
  cutlab_export_cancel(e);
  std::string st;
  for (int i = 0; i < 500; ++i) {
    st = status_of(e);
    if (str(st, "state") == "cancelled") break;
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  CHECK(str(st, "state") == "cancelled");
  cutlab_export_close(e);
  CHECK(!exists(s.path) && !exists(s.path + ".part"));
  // Closing a running export cancels it too.
  CHECK(cutlab_export_start(p.text.c_str(), s.text().c_str(), &e) == CUTLAB_OK);
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  cutlab_export_close(e);
  CHECK(!exists(s.path) && !exists(s.path + ".part"));
  // Start/cancel cycles.
  for (int i = 0; i < 10; ++i) {
    CHECK(cutlab_export_start(p.text.c_str(), s.text().c_str(), &e) == CUTLAB_OK);
    std::this_thread::sleep_for(std::chrono::milliseconds(i * 7));
    cutlab_export_cancel(e);
    cutlab_export_close(e);
  }
  CHECK(!exists(s.path) && !exists(s.path + ".part"));
}

void test_bad_media() {
  // An unreadable file and a cut-off file: the export completes, their
  // pictures are black, and it says so.
  const std::string garbage = out_path("garbage.mp4");
  {
    std::ofstream f(garbage, std::ios::binary);
    for (int i = 0; i < 20000; ++i) f.put(static_cast<char>((i * 7919) & 0xff));
  }
  const std::string cut = out_path("truncated.mp4");
  {
    std::ifstream in(media("gray60.mp4"), std::ios::binary);
    std::vector<char> all((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    std::ofstream f(cut, std::ios::binary);
    f.write(all.data(), static_cast<std::streamsize>(all.size() / 2));
  }
  const Plan p = Plan()
                     .track("v", "video")
                     .clip("g", garbage, 0, SEC, 0)
                     .clip("c", cut, SEC, 2 * SEC, 0)
                     .clip("ok", media("gray60.mp4"), 3 * SEC, SEC, 0)
                     .track("a", "audio")
                     .clip("ga", garbage, 0, SEC, 0)
                     .clip("t", media("tone1k.wav"), 3 * SEC, SEC, 0);
  Settings s;
  s.path = out_path("bad_media.mp4");
  s.video = g_codec;
  s.w = 320;
  s.h = 180;
  const std::string st = run_export(p, s);
  std::printf("bad media: %s\n", st.c_str());
  CHECK(str(st, "state") == "done");
  CHECK(st.find("could not be read") != std::string::npos);
  const Pic black = frame(s.path, 500 * MS);
  CHECK(black.ok && black.at(160, 90) < 24);
  const Pic good = frame(s.path, 3500 * MS);
  const Pic src = frame(media("gray60.mp4"), 500 * MS);
  CHECK(good.ok && src.ok);
  if (good.ok && src.ok) CHECK_NEAR(good.at(160, 90), src.at(src.w / 2, src.h / 2), 8);
  CHECK(rms(sound(s.path, 200 * MS, 9600)) < 0.01);
  CHECK_NEAR(rms(sound(s.path, 3300 * MS, 9600)), 0.5 / std::sqrt(2.0), 0.03);
  CHECK_NEAR(num(probe(s.path), "durationTicks") / SEC, 4.0, 0.06);
}

void test_hardware_fallback() {
  // Hardware allowed: whatever the machine has (often nothing in CI), the
  // export finishes, with a software encoder if the hardware ones fail.
  const Plan p = Plan().track("v", "video").clip("a", media("gray60.mp4"), 0, SEC, 0);
  Settings s;
  s.path = out_path("hw.mp4");
  s.video = g_codec;
  s.hardware = 1;
  const std::string st = run_export(p, s);
  std::printf("hardware allowed: %s\n", st.c_str());
  CHECK(str(st, "state") == "done");
  CHECK(exists(s.path));
}

void test_bitrate_mode() {
  const Plan p = Plan().track("v", "video").clip("a", media("gray60.mp4"), 0, 4 * SEC, 0);
  Settings lo, hi;
  lo.path = out_path("rate_lo.mp4");
  hi.path = out_path("rate_hi.mp4");
  lo.video = hi.video = g_codec;
  lo.audio = hi.audio = "none";
  lo.bitrate = 300;
  hi.bitrate = 3000;
  const std::string a = run_export(p, lo), b = run_export(p, hi);
  CHECK(str(a, "state") == "done" && str(b, "state") == "done");
  std::printf("bitrate: 300 kbit/s -> %.0f bytes, 3000 kbit/s -> %.0f bytes\n", num(a, "bytes"), num(b, "bytes"));
  CHECK(num(b, "bytes") > num(a, "bytes"));
}

void test_long_export() {
  // A 2-hour recording exported whole (small size so it runs in CI).
  const Plan p = Plan().track("v", "video").clip("l", media("long2h.mp4"), 0, 7200 * SEC, 0).track("t", "audio").clip("t", media("tone1k.wav"), 7190 * SEC, 6 * SEC, 0);
  Settings s;
  s.path = out_path("long.mp4");
  s.video = g_codec;
  s.w = 192;
  s.h = 108;
  s.fps = "24";
  double secs = 0;
  const std::string st = run_export(p, s, &secs, 3600);
  std::printf("2-hour export: %.1f s (%.0f fps): %s\n", secs, 7200 * 24 / std::max(secs, 1e-3), st.c_str());
  CHECK(str(st, "state") == "done");
  CHECK(num(st, "framesDone") == 7200 * 24);
  record(s.path, 192, 108, "24", 7200 * 24, g_codec, "aac");
  const std::string pr = probe(s.path);
  CHECK_NEAR(num(pr, "durationTicks") / SEC, 7200.0, 0.1);
  // Picture and sound are in place at the very end.
  const Pic o = frame(s.path, 7195 * SEC);
  const Pic src = frame(media("long2h.mp4"), 7195 * SEC);
  CHECK(o.ok && src.ok);
  if (o.ok && src.ok) CHECK_NEAR(o.at(o.w / 2, o.h / 2), src.at(src.w / 2, src.h / 2), 10);
  CHECK(rms(sound(s.path, 7189 * SEC, 9600)) < 0.01);
  CHECK_NEAR(rms(sound(s.path, 7192 * SEC, 9600)), 0.5 / std::sqrt(2.0), 0.03);
  // The tone starts exactly at 7190 s (no drift over two hours).
  const auto edge = sound(s.path, 7190 * SEC - 50 * MS, 9600);
  int first = -1;
  for (size_t i = 0; i < edge.size(); i += 2) {
    if (std::fabs(edge[i]) > 0.05) {
      first = static_cast<int>(i / 2);
      break;
    }
  }
  CHECK(first >= 0);
  if (first >= 0) CHECK_NEAR(first / 48000.0, 0.050, 0.003);
}

// Export speed on real-size recordings (scripts/make_android_test_media.sh):
// every software encoder in the build, plus hardware ones when allowed.
void bench(const std::string& real, const std::vector<Enc>& encs, bool hardware) {
  struct Job {
    const char* file;
    int w, h;
    const char* fps;
    double seconds;
  };
  const Job jobs[] = {{"h264_1080p60.mp4", 1920, 1080, "60", 3}, {"hevc_1080p60.mp4", 1920, 1080, "60", 3},
                      {"h264_1080p30.mp4", 1280, 720, "30", 3},  {"hevc10_4k30.mp4", 3840, 2160, "30", 2}};
  std::printf("export benchmark (%s):\n", hardware ? "hardware allowed" : "software");
  std::printf("%-22s %-10s %-10s %-14s %8s %8s %10s\n", "source", "output", "codec", "encoder", "fps", "x real", "kbit/s");
  for (const auto& j : jobs) {
    const std::string src = real + "/" + j.file;
    if (!exists(src)) continue;
    for (const char* codec : {"h264", "hevc", "vp9", "av1"}) {
      if (!hardware && !has_sw(encs, codec)) continue;
      const Plan p = Plan().track("v", "video").clip("a", src, 0, static_cast<int64_t>(j.seconds * SEC), 0);
      Settings s;
      s.path = out_path(std::string("bench_") + codec + "_" + std::to_string(j.h) + ".mp4");
      s.video = codec;
      s.w = j.w;
      s.h = j.h;
      s.fps = j.fps;
      s.speed = "balanced";
      s.hardware = hardware ? 1 : 0;
      double secs = 0;
      const std::string st = run_export(p, s, &secs, 1800);
      if (str(st, "state") != "done") {
        std::printf("%-22s %4dx%-5d %-10s failed: %s\n", j.file, j.w, j.h, codec, str(st, "error").c_str());
        continue;
      }
      const double frames = num(st, "framesDone");
      std::printf("%-22s %4dx%-5d %-10s %-14s %8.1f %8.2f %10.0f\n", j.file, j.w, j.h, codec, str(st, "encoder").c_str(), frames / secs,
                  j.seconds / secs, num(st, "bytes") * 8 / j.seconds / 1000);
    }
  }
}

}  // namespace

int main(int argc, char** argv) {
  const char* dir = std::getenv("CUTLAB_TEST_MEDIA");
  if (!dir) {
    std::fprintf(stderr, "set CUTLAB_TEST_MEDIA\n");
    return 2;
  }
  g_dir = dir;
  const char* out = std::getenv("CUTLAB_TEST_OUT");
  g_out = out ? out : ".";
  bool long_test = false, long_only = false, hw_bench = false;
  std::string bench_dir;
  for (int i = 1; i < argc; ++i) {
    const std::string a = argv[i];
    if (a == "--long") long_test = true;
    if (a == "--long-only") long_test = long_only = true;
    if (a == "--quick") g_quick = true;
    if (a == "--bench" && i + 1 < argc) bench_dir = argv[++i];
    if (a == "--hardware") hw_bench = true;
  }

  const auto encs = encoders();
  std::printf("encoders:");
  for (const auto& e : encs) std::printf(" %s(%s%s)", e.name.c_str(), e.codec.c_str(), e.hardware ? ",hw" : "");
  std::printf("\n");
  if (!has_sw(encs, "h264")) g_codec = has_sw(encs, "hevc") ? "hevc" : "mpeg4";
  // Valgrind runs use FFmpeg's own encoder, so the report is about CUTLAB's
  // code rather than the encoder libraries' hand-written assembly.
  if (const char* forced = std::getenv("CUTLAB_EXPORT_CODEC")) g_codec = forced;
  std::printf("timeline tests use %s\n", g_codec.c_str());

  if (!bench_dir.empty()) {
    bench(bench_dir, encs, hw_bench);
    return 0;
  }
  if (long_only) {
    test_long_export();
    std::printf("%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
  }
  test_settings_rejected();
  test_complete_timeline();
  test_mute_solo_master();
  test_formats(encs);
  test_resolutions_and_rates();
  test_cancel_and_pause();
  test_bad_media();
  test_hardware_fallback();
  test_bitrate_mode();
  if (long_test) test_long_export();

  std::printf("%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
