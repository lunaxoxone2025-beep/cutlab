// Effects and transitions, checked on rendered pictures (through the C ABI,
// as Flutter uses it). Needs scripts/make_test_media.sh; set CUTLAB_TEST_MEDIA.
//
//   cutlab_effects_tests [--quick] [--long]
//
// Every effect is applied to a test picture and the result is compared with
// the untouched picture at known places (a gray ramp, an orange and a blue
// area); transitions between two flat-colour clips are checked at known
// progress; continuity (no black or frozen frames) is checked on clips that
// encode the frame number in their brightness; exported files are decoded
// and compared with the composed picture (the one the preview shows), and
// the sound across cross-fades is measured.
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
bool g_quick = false;

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
    if (!(std::fabs(va - vb) <= (tol))) {                                                                           \
      ++g_failures;                                                                                                 \
      std::fprintf(stderr, "%s:%d: CHECK_NEAR failed: %s=%g vs %s=%g (tol %g)\n", __FILE__, __LINE__, #a, va, #b, vb, \
                   static_cast<double>(tol));                                                                       \
    }                                                                                                               \
  } while (0)

constexpr int64_t SEC = 705600000;
constexpr int64_t MS = SEC / 1000;

std::string media(const char* name) { return g_dir + "/" + name; }
std::string out_path(const std::string& name) { return g_out + "/" + name; }

double num(const std::string& json, const std::string& key, size_t from = 0) {
  const size_t k = json.find("\"" + key + "\":", from);
  return k == std::string::npos ? -1 : std::atof(json.c_str() + k + key.size() + 3);
}
std::string str(const std::string& json, const std::string& key, size_t from = 0) {
  const size_t k = json.find("\"" + key + "\":\"", from);
  if (k == std::string::npos) return "";
  const size_t b = k + key.size() + 4;
  return json.substr(b, json.find('"', b) - b);
}

struct Plan {
  std::string text = "cutlab-timeline 1\nhardware 0\n";
  Plan() = default;
  explicit Plan(int w, int h, const char* fps = "30 1") {
    text += "canvas " + std::to_string(w) + " " + std::to_string(h) + "\nfps " + fps + "\n";
  }
  Plan& track(const char* id, const char* kind) {
    text += std::string("track ") + id + " " + kind + " 0 0 0 1\n";
    return *this;
  }
  Plan& clip(const char* id, const std::string& file, int64_t start, int64_t dur, int64_t in, bool audio = true) {
    text += std::string("clip ") + id + " " + std::to_string(start) + " " + std::to_string(dur) + " " + std::to_string(in) + " 1 0 0 " +
            (audio ? "1" : "0") + " 0 1 " + file + "\n";
    return *this;
  }
  Plan& effect(const char* clip, const std::string& type, const std::string& params = "") {
    text += std::string("effect ") + clip + " " + type + (params.empty() ? "" : " " + params) + "\n";
    return *this;
  }
  Plan& vfade(const char* clip, int64_t in, int64_t out) {
    text += std::string("vfade ") + clip + " " + std::to_string(in) + " " + std::to_string(out) + "\n";
    return *this;
  }
  Plan& transition(const char* clip, const std::string& kind, int64_t left, int64_t right, const char* dir = "left") {
    text += std::string("transition ") + clip + " " + kind + " " + std::to_string(left) + " " + std::to_string(right) + " " + dir + "\n";
    return *this;
  }
  Plan& line(const std::string& l) {
    text += l + "\n";
    return *this;
  }
};

struct Img {
  int w = 0, h = 0;
  std::vector<uint8_t> px;
  bool ok = false;
  int at(int x, int y, int c) const { return px[(static_cast<size_t>(std::clamp(y, 0, h - 1)) * w + std::clamp(x, 0, w - 1)) * 4 + c]; }
  // Average of channel c over a 5x5 square.
  double avg(int x, int y, int c) const {
    double s = 0;
    for (int dy = -2; dy <= 2; ++dy)
      for (int dx = -2; dx <= 2; ++dx) s += at(x + dx, y + dy, c);
    return s / 25;
  }
  double luma(int x, int y) const { return 0.2126 * avg(x, y, 0) + 0.7152 * avg(x, y, 1) + 0.0722 * avg(x, y, 2); }
};

Img render(const Plan& p, int64_t t, int w = 320, int h = 180) {
  Img im;
  im.w = w;
  im.h = h;
  im.px.resize(static_cast<size_t>(w) * h * 4);
  im.ok = cutlab_render_frame(p.text.c_str(), t, w, h, im.px.data(), static_cast<int64_t>(im.px.size())) == CUTLAB_OK;
  if (!im.ok) std::fprintf(stderr, "render_frame: %s\n", cutlab_last_error());
  return im;
}

// Mean absolute difference over the RGB channels.
double diff(const Img& a, const Img& b) {
  if (a.w != b.w || a.h != b.h || a.px.empty()) return 1e9;
  double s = 0;
  for (size_t i = 0; i < a.px.size(); ++i) {
    if (i % 4 == 3) continue;
    s += std::abs(static_cast<int>(a.px[i]) - static_cast<int>(b.px[i]));
  }
  return s / (a.px.size() * 0.75);
}

Img decoded(const std::string& file, int64_t t, int w, int h) {
  Img im;
  uint8_t* rgba = nullptr;
  int32_t fw = 0, fh = 0;
  int64_t pts = 0;
  if (cutlab_media_frame(file.c_str(), t, w, h, 1, &rgba, &fw, &fh, &pts) == CUTLAB_OK && rgba) {
    im.w = fw;
    im.h = fh;
    im.px.assign(rgba, rgba + static_cast<size_t>(fw) * fh * 4);
    im.ok = true;
    cutlab_free(rgba);
  }
  return im;
}

// --------------------------------------------------------------- picture

// colors.mp4 (320x180): gray ramp on the left half (x 0..159, value
// x*255/159), orange (200, 80, 40) top right, blue (40, 90, 200) bottom right.
constexpr int kDarkX = 40, kBrightX = 120, kRampY = 45;  // ramp ~64 and ~192
constexpr int kOrX = 240, kOrY = 45, kBlX = 240, kBlY = 135;

Plan picture_plan() { return Plan(320, 180).track("v", "video").clip("c", media("colors.mp4"), 0, 3 * SEC, 0, false); }

Img with(const std::string& type, const std::string& params = "") {
  Plan p = picture_plan();
  p.effect("c", type, params);
  return render(p, SEC);
}

double sat(const Img& im, int x, int y) {
  const double r = im.avg(x, y, 0), g = im.avg(x, y, 1), b = im.avg(x, y, 2);
  return std::max(r, std::max(g, b)) - std::min(r, std::min(g, b));
}

void test_catalog() {
  char* js = nullptr;
  CHECK(cutlab_effect_catalog(&js) == CUTLAB_OK && js);
  const std::string s = js ? js : "";
  cutlab_free(js);
  for (const char* t : {"brightness", "contrast", "saturation", "vibrance", "exposure", "gamma", "temperature", "tint", "highlights", "shadows",
                        "sharpen", "blur", "vignette", "grayscale", "black_white", "sepia", "rgb", "filter"})
    CHECK(s.find(std::string("\"type\":\"") + t + "\"") != std::string::npos);
  for (const char* t : {"dissolve", "dip_black", "dip_white", "wipe", "slide", "zoom_in", "zoom_out", "blur"})
    CHECK(s.find(std::string("\"") + t + "\"") != std::string::npos);
  CHECK(s.find("teal_orange") != std::string::npos && s.find("matte") != std::string::npos);
}

void test_plan_rejects() {
  auto parses = [](const Plan& p) {
    cutlab_timeline* t = nullptr;
    if (cutlab_timeline_open(64, 64, 2, &t) != CUTLAB_OK) return false;
    const bool ok = cutlab_timeline_set_plan(t, p.text.c_str()) == CUTLAB_OK;
    cutlab_timeline_close(t);
    return ok;
  };
  CHECK(parses(Plan(picture_plan()).effect("c", "brightness", "amount=0.2")));
  CHECK(!parses(Plan(picture_plan()).effect("c", "glow")));                       // unknown effect
  CHECK(!parses(Plan(picture_plan()).effect("c", "brightness", "power=1")));      // unknown parameter
  CHECK(!parses(Plan(picture_plan()).effect("nope", "brightness")));              // unknown clip
  CHECK(!parses(Plan(picture_plan()).transition("c", "spin", SEC, SEC)));         // unknown transition
  CHECK(!parses(Plan(picture_plan()).transition("c", "wipe", SEC, SEC, "diag")));  // unknown direction
  // Out-of-range values are clamped: brightness 5 = brightness 1.
  CHECK(diff(with("brightness", "amount=5"), with("brightness", "amount=1")) < 0.01);
}

void test_each_effect() {
  const Img base = render(picture_plan(), SEC);
  CHECK(base.ok);
  if (!base.ok) return;
  std::printf("source: ramp %.0f/%.0f, orange %.0f,%.0f,%.0f, blue %.0f,%.0f,%.0f\n", base.avg(kDarkX, kRampY, 0), base.avg(kBrightX, kRampY, 0),
              base.avg(kOrX, kOrY, 0), base.avg(kOrX, kOrY, 1), base.avg(kOrX, kOrY, 2), base.avg(kBlX, kBlY, 0), base.avg(kBlX, kBlY, 1),
              base.avg(kBlX, kBlY, 2));
  CHECK_NEAR(base.avg(kDarkX, kRampY, 0), 64, 6);
  CHECK_NEAR(base.avg(kOrX, kOrY, 0), 200, 6);
  // Defaults are neutral where they should be (an effect at its default
  // changes nothing).
  for (const char* t : {"brightness", "contrast", "saturation", "vibrance", "exposure", "gamma", "temperature", "tint", "highlights", "shadows", "rgb"})
    CHECK(diff(with(t), base) < 0.6);
  // Brightness +0.5 lifts everything by 0.2 (51 levels).
  {
    const Img im = with("brightness", "amount=0.5");
    CHECK_NEAR(im.avg(kDarkX, kRampY, 0) - base.avg(kDarkX, kRampY, 0), 51, 4);
    CHECK(with("brightness", "amount=-0.5").avg(kBrightX, kRampY, 0) < base.avg(kBrightX, kRampY, 0) - 40);
  }
  {  // Contrast: darks darker, brights brighter; negative flattens.
    const Img im = with("contrast", "amount=0.5");
    CHECK(im.avg(kDarkX, kRampY, 0) < base.avg(kDarkX, kRampY, 0) - 30);
    CHECK(im.avg(kBrightX, kRampY, 0) > base.avg(kBrightX, kRampY, 0) + 30);
    const Img flat = with("contrast", "amount=-1");
    CHECK_NEAR(flat.avg(kDarkX, kRampY, 0), 128, 3);
  }
  {  // Saturation -1: gray; +1: more colourful.
    const Img gray = with("saturation", "amount=-1");
    CHECK(sat(gray, kOrX, kOrY) < 3 && sat(gray, kBlX, kBlY) < 3);
    CHECK(sat(with("saturation", "amount=0.5"), kOrX, kOrY) > sat(base, kOrX, kOrY) + 20);
  }
  {  // Vibrance boosts colour, gray stays gray.
    const Img im = with("vibrance", "amount=1");
    CHECK(sat(im, kOrX, kOrY) > sat(base, kOrX, kOrY) + 10);
    CHECK(sat(im, kDarkX, kRampY) < 3);
    CHECK(sat(with("vibrance", "amount=-1"), kOrX, kOrY) < sat(base, kOrX, kOrY) - 10);
  }
  {  // Exposure +1 stop and gamma 2 brighten the mid-tones.
    CHECK(with("exposure", "stops=1").avg(kDarkX, kRampY, 1) > base.avg(kDarkX, kRampY, 1) + 15);
    CHECK(with("exposure", "stops=-1").avg(kBrightX, kRampY, 1) < base.avg(kBrightX, kRampY, 1) - 15);
    CHECK_NEAR(with("gamma", "value=2").avg(kDarkX, kRampY, 1), 255 * std::sqrt(base.avg(kDarkX, kRampY, 1) / 255), 4);
  }
  {  // Temperature: warmer = more red, less blue. Tint: + = magenta (less green).
    const Img warm = with("temperature", "amount=1");
    CHECK(warm.avg(kBlX, kBlY, 0) > base.avg(kBlX, kBlY, 0) + 5);
    CHECK(warm.avg(kBlX, kBlY, 2) < base.avg(kBlX, kBlY, 2) - 30);
    const Img cool = with("temperature", "amount=-1");
    CHECK(cool.avg(kOrX, kOrY, 0) < base.avg(kOrX, kOrY, 0) - 30);
    const Img tint = with("tint", "amount=1");
    CHECK(tint.avg(kBrightX, kRampY, 1) < base.avg(kBrightX, kRampY, 1) - 25);
    CHECK(with("tint", "amount=-1").avg(kBrightX, kRampY, 1) > base.avg(kBrightX, kRampY, 1) + 20);
  }
  {  // Highlights change the bright part only; shadows the dark part only.
    const Img hl = with("highlights", "amount=-1");
    CHECK(hl.avg(kBrightX, kRampY, 1) < base.avg(kBrightX, kRampY, 1) - 12);
    CHECK_NEAR(hl.avg(kDarkX, kRampY, 1), base.avg(kDarkX, kRampY, 1), 2);
    const Img sh = with("shadows", "amount=1");
    CHECK(sh.avg(kDarkX, kRampY, 1) > base.avg(kDarkX, kRampY, 1) + 12);
    CHECK_NEAR(sh.avg(kBrightX, kRampY, 1), base.avg(kBrightX, kRampY, 1), 2);
  }
  {  // Blur softens the orange/blue edge (y = 90); sharpen overshoots it.
    const Img bl = with("blur", "radius=0.02");
    CHECK(bl.at(kOrX, 87, 0) < base.at(kOrX, 87, 0) - 20);
    CHECK(bl.at(kOrX, 92, 0) > base.at(kOrX, 92, 0) + 20);
    CHECK_NEAR(bl.avg(kOrX, 30, 0), base.avg(kOrX, 30, 0), 3);  // flat areas stay
    const Img sh = with("sharpen", "amount=2,radius=0.01");
    CHECK(sh.at(kOrX, 88, 0) > base.at(kOrX, 88, 0) + 8);
    CHECK(sh.at(kOrX, 92, 0) < base.at(kOrX, 92, 0) - 8);
  }
  {  // Vignette darkens the corners, not the middle.
    const Img v = with("vignette", "amount=1,size=0.5,softness=0.3");
    CHECK(v.avg(316, 3, 0) < base.avg(316, 3, 0) * 0.3);
    CHECK_NEAR(v.avg(190, 80, 0), base.avg(190, 80, 0), 2);
  }
  {  // Grayscale, black & white, sepia.
    const Img g = with("grayscale");
    CHECK(sat(g, kOrX, kOrY) < 3 && sat(g, kBlX, kBlY) < 3);
    const Img half = with("grayscale", "amount=0.5");
    CHECK(sat(half, kOrX, kOrY) > 20 && sat(half, kOrX, kOrY) < sat(base, kOrX, kOrY) - 20);
    const Img bw = with("black_white", "threshold=0.5,softness=0");
    CHECK(bw.at(kDarkX, kRampY, 0) == 0 && bw.at(kBrightX, kRampY, 0) == 255);
    CHECK(bw.at(kOrX, kOrY, 1) == 0);  // orange luma ~0.4
    const Img sp = with("sepia");
    CHECK(sp.avg(kBlX, kBlY, 0) > sp.avg(kBlX, kBlY, 1) && sp.avg(kBlX, kBlY, 1) > sp.avg(kBlX, kBlY, 2));  // blue becomes brown
  }
  {  // RGB gains and offsets.
    const Img r0 = with("rgb", "red=0");
    CHECK(r0.avg(kOrX, kOrY, 0) < 3);
    CHECK_NEAR(r0.avg(kOrX, kOrY, 1), base.avg(kOrX, kOrY, 1), 2);
    const Img off = with("rgb", "blue_offset=0.2");
    CHECK_NEAR(off.avg(kDarkX, kRampY, 2) - base.avg(kDarkX, kRampY, 2), 51, 3);
  }
  // Every filter look changes the picture; noir is monochrome.
  for (int look = 0; look < 8; ++look) {
    const Img f = with("filter", "look=" + std::to_string(look));
    CHECK(diff(f, base) > 3);
    const Img weak = with("filter", "look=" + std::to_string(look) + ",amount=0.25");
    CHECK(diff(weak, base) < diff(f, base));
  }
  CHECK(sat(with("filter", "look=4"), kOrX, kOrY) < 3);
  CHECK(with("filter", "look=0").avg(kBlX, kBlY, 2) > with("filter", "look=0").avg(kOrX, kOrY, 2));  // teal/orange split
}

void test_multiple_effects() {
  const Img base = render(picture_plan(), SEC);
  // Effects apply in their order: desaturate then warm keeps a red tint;
  // warm then desaturate is neutral gray.
  Plan a = picture_plan();
  a.effect("c", "saturation", "amount=-1").effect("c", "temperature", "amount=1");
  Plan b = picture_plan();
  b.effect("c", "temperature", "amount=1").effect("c", "saturation", "amount=-1");
  const Img ia = render(a, SEC), ib = render(b, SEC);
  CHECK(ia.avg(kBrightX, kRampY, 0) > ia.avg(kBrightX, kRampY, 2) + 20);
  CHECK(sat(ib, kBrightX, kRampY) < 3 && sat(ib, kOrX, kOrY) < 3);
  // A long chain (one of each kind) runs and differs from every single one.
  Plan c = picture_plan();
  c.effect("c", "exposure", "stops=0.3")
      .effect("c", "contrast", "amount=0.2")
      .effect("c", "vibrance", "amount=0.4")
      .effect("c", "filter", "look=0,amount=0.6")
      .effect("c", "sharpen", "amount=0.5")
      .effect("c", "vignette", "amount=0.4");
  const Img ic = render(c, SEC);
  CHECK(ic.ok && diff(ic, base) > 5);
  CHECK(diff(ic, with("vignette", "amount=0.4")) > 3);
  // Effects belong to their clip only: a second clip after it is untouched.
  Plan d = Plan(320, 180).track("v", "video").clip("c", media("colors.mp4"), 0, SEC, 0, false).clip("d", media("colors.mp4"), SEC, SEC, 0, false);
  d.effect("c", "grayscale");
  CHECK(sat(render(d, SEC / 2), kOrX, kOrY) < 3);
  CHECK(sat(render(d, SEC + SEC / 2), kOrX, kOrY) > 100);
  // Sizes are relative to the frame height: a blur looks the same at 2x.
  Plan e = picture_plan();
  e.effect("c", "blur", "radius=0.02");
  const Img small = render(e, SEC), big = render(e, SEC, 640, 360);
  CHECK_NEAR(small.at(kOrX, 87, 0), big.avg(kOrX * 2, 87 * 2 + 1, 0), 8);
}

void test_video_fades() {
  Plan p = picture_plan();
  p.vfade("c", SEC / 2, SEC / 2);
  const Img base = render(picture_plan(), SEC);
  CHECK(render(p, 0).avg(kOrX, kOrY, 0) < 3);                                       // starts black
  CHECK_NEAR(render(p, SEC / 4).avg(kOrX, kOrY, 0), base.avg(kOrX, kOrY, 0) / 2, 4);  // half way
  CHECK(diff(render(p, SEC), base) < 0.6);                                         // full picture between
  CHECK_NEAR(render(p, 3 * SEC - SEC / 4).avg(kOrX, kOrY, 0), base.avg(kOrX, kOrY, 0) / 2, 4);
  CHECK(render(p, 3 * SEC - MS).avg(kOrX, kOrY, 0) < 3);  // ends black
}

// ------------------------------------------------------------ transitions

// red [0, 2 s) (media 0..2 s of 6), blue [2 s, 4 s) (media 1..3 s), cut at 2 s.
Plan two_flats(const std::string& kind, int64_t left, int64_t right, const char* dir = "left", const char* fps = "30 1") {
  Plan p(320, 180, fps);
  p.track("v", "video").clip("a", media("flat_red.mkv"), 0, 2 * SEC, 0).clip("b", media("flat_blue.mkv"), 2 * SEC, 2 * SEC, SEC);
  p.transition("b", kind, left, right, dir);
  return p;
}

bool is_red(const Img& im, int x, int y) { return im.avg(x, y, 0) > 190 && im.avg(x, y, 2) < 90; }
bool is_blue(const Img& im, int x, int y) { return im.avg(x, y, 2) > 190 && im.avg(x, y, 0) < 80; }

void test_transitions() {
  const int64_t H = SEC / 2;
  for (const char* k : {"dissolve", "dip_black", "dip_white", "wipe", "slide", "zoom_in", "zoom_out", "blur"}) {
    const Plan p = two_flats(k, H, H);
    // Outside the transition: the clips as they are.
    CHECK(is_red(render(p, SEC), 160, 90));
    CHECK(is_blue(render(p, 3 * SEC), 160, 90));
  }
  {  // Cross dissolve (and the blur transition, on flat pictures): the average at the middle.
    for (const char* k : {"dissolve", "blur"}) {
      const Img m = render(two_flats(k, H, H), 2 * SEC);
      CHECK_NEAR(m.avg(160, 90, 0), (220 + 50) / 2.0, 8);
      CHECK_NEAR(m.avg(160, 90, 2), (60 + 220) / 2.0, 8);
    }
    const Img q = render(two_flats("dissolve", H, H), 2 * SEC - SEC / 4);  // a quarter of the way
    CHECK_NEAR(q.avg(160, 90, 0), 220 * 0.75 + 50 * 0.25, 8);
  }
  {  // Dips: half way into the colour, the colour at the cut.
    const Img b1 = render(two_flats("dip_black", H, H), 2 * SEC - SEC / 4);
    CHECK_NEAR(b1.avg(160, 90, 0), 110, 8);
    CHECK(render(two_flats("dip_black", H, H), 2 * SEC).avg(160, 90, 2) < 10);
    const Img b3 = render(two_flats("dip_black", H, H), 2 * SEC + SEC / 4);
    CHECK_NEAR(b3.avg(160, 90, 2), 110, 8);
    CHECK(render(two_flats("dip_white", H, H), 2 * SEC).avg(160, 90, 0) > 245);
    CHECK_NEAR(render(two_flats("dip_white", H, H), 2 * SEC - SEC / 4).avg(160, 90, 1), (60 + 255) / 2.0, 8);
    // Dips need no media beyond the cut: asymmetric durations work.
    CHECK_NEAR(render(two_flats("dip_black", SEC, H), SEC + SEC / 2).avg(160, 90, 0), 110, 8);
  }
  {  // Wipes: the edge half way across, from the named side.
    const Img l = render(two_flats("wipe", H, H, "left"), 2 * SEC);
    CHECK(is_red(l, 20, 90) && is_blue(l, 300, 90));
    const Img r = render(two_flats("wipe", H, H, "right"), 2 * SEC);
    CHECK(is_blue(r, 20, 90) && is_red(r, 300, 90));
    const Img u = render(two_flats("wipe", H, H, "up"), 2 * SEC);
    CHECK(is_red(u, 160, 10) && is_blue(u, 160, 170));
    const Img d = render(two_flats("wipe", H, H, "down"), 2 * SEC);
    CHECK(is_blue(d, 160, 10) && is_red(d, 160, 170));
    const Img q = render(two_flats("wipe", H, H, "left"), 2 * SEC - SEC / 4);  // a quarter: edge near x = 240
    CHECK(is_red(q, 225, 90) && is_blue(q, 255, 90));
  }
  {  // Slides: eased, so a quarter of the time is ~16% of the width.
    const Img m = render(two_flats("slide", H, H, "left"), 2 * SEC);
    CHECK(is_red(m, 150, 90) && is_blue(m, 170, 90));
    const Img q = render(two_flats("slide", H, H, "left"), 2 * SEC - SEC / 4);
    CHECK(is_red(q, 260, 90) && is_blue(q, 280, 90));
    const Img r = render(two_flats("slide", H, H, "right"), 2 * SEC - SEC / 4);
    CHECK(is_blue(r, 40, 90) && is_red(r, 60, 90));
    const Img u = render(two_flats("slide", H, H, "up"), 2 * SEC);
    CHECK(is_red(u, 160, 80) && is_blue(u, 160, 100));
    const Img dn = render(two_flats("slide", H, H, "down"), 2 * SEC);
    CHECK(is_blue(dn, 160, 80) && is_red(dn, 160, 100));
  }
  {  // Zooms: mixed in the middle, the outer clip at the corners.
    const Img zi = render(two_flats("zoom_in", H, H), 2 * SEC);
    CHECK_NEAR(zi.avg(160, 90, 0), 135, 10);
    CHECK(is_red(zi, 3, 3));  // B (smaller) does not reach the corner yet
    const Img zo = render(two_flats("zoom_out", H, H), 2 * SEC);
    CHECK_NEAR(zo.avg(160, 90, 0), 135, 10);
    CHECK(is_blue(zo, 3, 3));  // A (shrinking) left the corner
  }
}

// gray60.mp4 / gray120.mkv: brightness = frame number. A shows media from 0
// at [0, 2 s), B media from b_in at [2 s, 4 s). With a wipe, the left edge
// shows A and the right edge B through most of the transition: every output
// frame must show exactly the source frame due at that time (no frozen,
// repeated or skipped frames), and never black.
void continuity(const std::string& kind, const char* fps_text, int64_t fnum, int64_t fden, const char* file, int64_t b_in) {
  Plan p(320, 180, fps_text);
  p.track("v", "video").clip("a", media(file), 0, 2 * SEC, 0, false).clip("b", media(file), 2 * SEC, 2 * SEC, b_in, false);
  p.transition("b", kind, SEC / 2, SEC / 2, "left");
  int64_t n0 = 0, n1 = 0;
  cutlab_ticks_to_frames(14 * SEC / 10, fnum, fden, CUTLAB_ROUND_NEAREST, &n0);
  cutlab_ticks_to_frames(26 * SEC / 10, fnum, fden, CUTLAB_ROUND_NEAREST, &n1);
  int bad = 0, black = 0, frames = 0, checked = 0;
  double first_a = -1, last_a = -1, first_b = -1, last_b = -1;
  int64_t ta0 = 0, ta1 = 0, tb0 = 0, tb1 = 0;
  for (int64_t n = n0; n <= n1; ++n) {
    int64_t t = 0;
    cutlab_frames_to_ticks(n, fnum, fden, &t);
    const Img im = render(p, t, 160, 90);
    if (!im.ok) {
      ++bad;
      continue;
    }
    ++frames;
    const double pr = std::clamp((static_cast<double>(t) / SEC - 1.5) / 1.0, 0.0, 1.0);
    if (im.luma(80, 45) < 20) ++black;
    // The edge pixels belong to one clip while the wipe has not reached them.
    auto expect = [&](int64_t src, int x, const char* which) {
      const Img want = decoded(media(file), src, 160, 90);
      ++checked;
      if (!want.ok || std::fabs(im.avg(x, 45, 1) - want.avg(x, 45, 1)) > 1.01) {
        ++bad;
        std::printf("  %s at %.4f s: shows %.1f, source frame due %.1f\n", which, static_cast<double>(t) / SEC, im.avg(x, 45, 1),
                    want.ok ? want.avg(x, 45, 1) : -1.0);
      }
      return im.avg(x, 45, 1);
    };
    if (pr < 0.9) {
      last_a = expect(t, 1, "A");
      ta1 = t;
      if (first_a < 0) {
        first_a = last_a;
        ta0 = t;
      }
    }
    if (pr > 0.1) {
      last_b = expect(b_in + (t - 2 * SEC), 158, "B");
      tb1 = t;
      if (first_b < 0) {
        first_b = last_b;
        tb0 = t;
      }
    }
  }
  // Both pictures move on at the source rate: about one gray level per
  // source frame (the level wraps at 256).
  const double src_fps = std::string(file).find("120") != std::string::npos ? 120 : 60;
  auto wrap = [](double d) { return d < 0 ? d + 256 : d; };
  const double slope_a = wrap(last_a - first_a) / (static_cast<double>(ta1 - ta0) / SEC);
  const double slope_b = wrap(last_b - first_b) / (static_cast<double>(tb1 - tb0) / SEC);
  std::printf("continuity %s at %s fps, %s: %d frames (%d checked), %d wrong, %d black; levels/s A %.0f B %.0f (source %.0f fps)\n", kind.c_str(),
              fps_text, file, frames, checked, bad, black, slope_a, slope_b, src_fps);
  CHECK(frames == n1 - n0 + 1);
  CHECK(bad == 0);
  CHECK(black == 0);
  CHECK(slope_a > src_fps * 0.85 && slope_a < src_fps * 1.3);
  CHECK(slope_b > src_fps * 0.85 && slope_b < src_fps * 1.3);
}

void test_continuity() {
  continuity("wipe", "60 1", 60, 1, "gray60.mp4", 6 * SEC);
  continuity("wipe", "30 1", 30, 1, "gray60.mp4", 6 * SEC);
  continuity("wipe", "24 1", 24, 1, "gray60.mp4", 6 * SEC);
  continuity("wipe", "30000 1001", 30000, 1001, "gray60.mp4", 6 * SEC);
  continuity("wipe", "60 1", 60, 1, "gray120.mkv", 2 * SEC + SEC / 2);
  continuity("slide", "120 1", 120, 1, "gray120.mkv", 2 * SEC + SEC / 2);
  // A clip without media before its in-point: the overlap shortens to the
  // part after the cut (no frozen first frame of B before the cut).
  Plan p(320, 180, "60 1");
  p.track("v", "video").clip("a", media("gray60.mp4"), 0, 2 * SEC, 0, false).clip("b", media("gray60.mp4"), 2 * SEC, 2 * SEC, 0, false);
  p.transition("b", "dissolve", SEC / 2, SEC / 2);
  CHECK(diff(render(p, 2 * SEC - SEC / 4), render(Plan(320, 180, "60 1").track("v", "video").clip("a", media("gray60.mp4"), 0, 2 * SEC, 0, false),
                                                  2 * SEC - SEC / 4)) < 0.6);
}

// ------------------------------------------------------- player = render

void test_preview_matches() {
  Plan p = two_flats("wipe", SEC / 2, SEC / 2, "up");
  p.effect("a", "vignette", "amount=0.8").effect("b", "filter", "look=3");
  cutlab_timeline* t = nullptr;
  CHECK(cutlab_timeline_open(320, 180, 2, &t) == CUTLAB_OK);
  if (!t) return;
  CHECK(cutlab_timeline_set_plan(t, p.text.c_str()) == CUTLAB_OK);
  std::vector<uint8_t> buf(320 * 180 * 4);
  uint64_t serial = 0;
  for (const int64_t at : {SEC, 2 * SEC - SEC / 4, 2 * SEC, 3 * SEC}) {
    cutlab_timeline_seek(t, at, 1);
    Img shown;
    for (int i = 0; i < 300 && !shown.ok; ++i) {
      int32_t w = 0, h = 0;
      int64_t pts = 0;
      if (cutlab_timeline_frame(t, &serial, buf.data(), static_cast<int64_t>(buf.size()), &w, &h, &pts) && pts == at && w == 320) {
        shown.w = w;
        shown.h = h;
        shown.px = buf;
        shown.ok = true;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    CHECK(shown.ok);
    if (shown.ok) CHECK(diff(shown, render(p, at)) < 0.01);  // the very same picture
  }
  // Playing across the transition: pictures keep coming, no black.
  cutlab_timeline_seek(t, SEC + SEC / 2, 1);
  cutlab_timeline_play(t);
  int shown = 0, black = 0;
  int64_t last = -1;
  bool forward = true;
  const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(1500);
  while (std::chrono::steady_clock::now() < end) {
    int32_t w = 0, h = 0;
    int64_t pts = 0;
    if (cutlab_timeline_frame(t, &serial, buf.data(), static_cast<int64_t>(buf.size()), &w, &h, &pts)) {
      ++shown;
      if (w == 0) ++black;
      if (pts <= last) forward = false;
      last = pts;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(4));
  }
  char* js = nullptr;
  cutlab_timeline_stats(t, &js);
  const std::string st = js ? js : "";
  cutlab_free(js);
  std::printf("preview across a transition: %d pictures in 1.5 s, stats %s\n", shown, st.c_str());
  // (Under valgrind everything runs ~50x slower: only a few pictures.)
  CHECK(shown >= (std::getenv("CUTLAB_UNDER_VALGRIND") ? 3 : 30));
  CHECK(black == 0);
  CHECK(forward);
  CHECK(str(st, "videoError").empty());
  cutlab_timeline_close(t);
}

// ------------------------------------------------------------ export

struct Settings {
  std::string path, codec = "h264", fps = "30";
  int w = 320, h = 180;
  std::string text() const {
    return "path " + path + "\ncontainer mp4\nvideo " + codec + "\nsize " + std::to_string(w) + "x" + std::to_string(h) + "\nfps " + fps +
           "\nquality 95\nspeed fast\nhardware 0\naudio aac\n";
  }
};

std::string run_export(const Plan& plan, const Settings& s, double* seconds = nullptr) {
  cutlab_export* e = nullptr;
  const auto t0 = std::chrono::steady_clock::now();
  if (cutlab_export_start(plan.text.c_str(), s.text().c_str(), &e) != CUTLAB_OK) {
    std::fprintf(stderr, "export_start failed: %s\n", cutlab_last_error());
    return "";
  }
  std::string st;
  for (;;) {
    char* js = nullptr;
    cutlab_export_status(e, &js);
    st = js ? js : "";
    cutlab_free(js);
    const std::string state = str(st, "state");
    if (state == "done" || state == "failed" || state == "cancelled") break;
    if (std::chrono::steady_clock::now() - t0 > std::chrono::seconds(3600)) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  }
  if (seconds) *seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  cutlab_export_close(e);
  if (str(st, "state") != "done") std::fprintf(stderr, "export of %s: %s\n", s.path.c_str(), st.c_str());
  return st;
}

std::string g_codec = "h264";

void record(const std::string& file, int w, int h, const std::string& fps, int64_t frames) {
  std::ofstream m(g_out + "/exports.txt", std::ios::app);
  const auto slash = file.find_last_of("/\\");
  m << file.substr(slash == std::string::npos ? 0 : slash + 1) << '|' << w << '|' << h << '|' << fps << '|' << frames << '|' << g_codec << "|aac\n";
}

std::vector<float> sound_of(const Plan& p, int64_t start, int frames) {
  std::vector<float> out(static_cast<size_t>(frames) * 2, 0.0f);
  cutlab_timeline* t = nullptr;
  if (cutlab_timeline_open(64, 64, 2, &t) != CUTLAB_OK) return out;
  cutlab_timeline_set_plan(t, p.text.c_str());
  cutlab_timeline_render_audio(t, start, frames, out.data(), nullptr, 0);
  cutlab_timeline_close(t);
  return out;
}

// RMS of 10 ms blocks of the left channel.
std::vector<double> block_rms(const std::vector<float>& s) {
  std::vector<double> out;
  const size_t n = 480;
  for (size_t b = 0; (b + 1) * n * 2 <= s.size(); ++b) {
    double sum = 0;
    for (size_t i = 0; i < n; ++i) sum += static_cast<double>(s[(b * n + i) * 2]) * s[(b * n + i) * 2];
    out.push_back(std::sqrt(sum / n));
  }
  return out;
}

void check_steady(const std::vector<double>& blocks, const char* what) {
  double lo = 1e9, hi = 0;
  for (const double r : blocks) {
    lo = std::min(lo, r);
    hi = std::max(hi, r);
  }
  std::printf("%s: 10 ms RMS %.3f..%.3f (steady tone 0.283)\n", what, lo, hi);
  CHECK(!blocks.empty());
  CHECK(lo > 0.2);   // no dropout
  CHECK(hi < 0.36);  // no doubling
}

void test_audio_continuity() {
  // Cross-fade between a 500 Hz and a 700 Hz tone (equal power: steady).
  for (const char* k : {"dissolve", "wipe", "zoom_in"}) {
    const auto s = sound_of(two_flats(k, SEC / 2, SEC / 2), SEC + SEC / 3, 48000 + 48000 / 3);
    check_steady(block_rms(s), (std::string("sound across ") + k).c_str());
  }
  // Dips and transitions without overlap keep a straight cut.
  check_steady(block_rms(sound_of(two_flats("dip_black", SEC / 2, SEC / 2), SEC + SEC / 2, 48000)), "sound across dip_black");
  // No sound of B before its lead-in starts, none of A after its tail.
  const auto early = sound_of(two_flats("dissolve", SEC / 4, SEC / 4), SEC, 4800);
  double peak = 0;
  for (const float v : early) peak = std::max(peak, static_cast<double>(std::fabs(v)));
  CHECK_NEAR(peak, 0.4, 0.02);  // only A, at full level
}

void test_export_consistency() {
  // Effects on both clips, a video fade out, a dissolve between them.
  Plan p = Plan(320, 180).track("v", "video").clip("a", media("colors.mp4"), 0, 2 * SEC, 0, false).clip("b", media("flat_blue.mkv"), 2 * SEC, 2 * SEC, SEC);
  p.effect("a", "brightness", "amount=0.2").effect("a", "vignette", "amount=0.7").effect("a", "filter", "look=0");
  p.effect("b", "sepia", "amount=0.6");
  p.vfade("b", 0, SEC / 2);
  p.transition("b", "dissolve", SEC / 2, SEC / 2);
  Settings s;
  s.path = out_path("effects.mp4");
  s.codec = g_codec;
  double secs = 0;
  const std::string st = run_export(p, s, &secs);
  CHECK(str(st, "state") == "done");
  CHECK(num(st, "framesDone") == 120);
  record(s.path, 320, 180, "30", 120);
  // Each exported frame is the composed picture (the one the preview shows),
  // within coding loss; the picture without effects is far from it.
  Plan plain = Plan(320, 180).track("v", "video").clip("a", media("colors.mp4"), 0, 2 * SEC, 0, false).clip("b", media("flat_blue.mkv"), 2 * SEC, 2 * SEC, SEC);
  for (const int64_t t : {SEC / 2, SEC + SEC / 2 + SEC / 6, 2 * SEC, 2 * SEC + SEC / 3, 3 * SEC, 4 * SEC - SEC / 6}) {
    const Img out = decoded(s.path, t + SEC / 60, 320, 180);
    const Img want = render(p, t), bare = render(plain, t);
    CHECK(out.ok && out.w == 320);
    const double d = diff(out, want), d0 = diff(out, bare);
    std::printf("export at %.2f s: differs from the composed picture by %.2f, from the plain one by %.2f\n", static_cast<double>(t) / SEC, d, d0);
    CHECK(d < 6);
    CHECK(d0 > d + 4);
  }
  // The fade out reaches black at the end.
  CHECK(decoded(s.path, 4 * SEC - SEC / 60, 320, 180).luma(160, 90) < 20);
  // Sound in an exported file runs through a cross-fade without a gap.
  {
    Settings as;
    as.path = out_path("crossfade.mp4");
    as.codec = g_codec;
    const std::string ast = run_export(two_flats("dissolve", SEC / 2, SEC / 2), as);
    CHECK(str(ast, "state") == "done");
    record(as.path, 320, 180, "30", 120);
    Plan audio_only;
    audio_only.track("x", "audio").clip("x", as.path, 0, 10 * SEC, 0);
    check_steady(block_rms(sound_of(audio_only, 2 * SEC - SEC * 2 / 3, 64000)), "exported sound across the dissolve");
    const Img mid = decoded(as.path, 2 * SEC + SEC / 60, 320, 180);
    CHECK(mid.ok && std::fabs(mid.avg(160, 90, 0) - 135) < 10);  // the dissolve is in the file
  }

  // Other frame rates: a wipe exported at 24 and 60 fps, checked frame by frame.
  for (const char* fps : {"24", "60"}) {
    Plan w(320, 180, fps[0] == '2' ? "24 1" : "60 1");
    w.track("v", "video").clip("a", media("gray60.mp4"), 0, 2 * SEC, 0, false).clip("b", media("gray60.mp4"), 2 * SEC, 2 * SEC, 6 * SEC, false);
    w.transition("b", "wipe", SEC / 2, SEC / 2, "left");
    Settings ws;
    ws.path = out_path(std::string("wipe") + fps + ".mp4");
    ws.codec = g_codec;
    ws.fps = fps;
    const std::string wst = run_export(w, ws);
    CHECK(str(wst, "state") == "done");
    const int f = std::atoi(fps);
    CHECK(num(wst, "framesDone") == 4 * f);
    record(ws.path, 320, 180, fps, 4 * f);
    int worst = 0;
    for (int n = static_cast<int>(1.4 * f); n <= static_cast<int>(2.6 * f); n += 3) {
      const int64_t t = SEC * n / f;
      const Img o = decoded(ws.path, t + SEC / (2 * f), 320, 180), want = render(w, t);
      worst = std::max(worst, static_cast<int>(diff(o, want)));
    }
    std::printf("wipe exported at %s fps: worst frame difference %d\n", fps, worst);
    CHECK(worst < 6);
  }
}

// ------------------------------------------------- long timeline, memory

int64_t rss_kib() {
  cutlab_timeline* t = nullptr;
  if (cutlab_timeline_open(16, 16, 2, &t) != CUTLAB_OK) return -1;
  char* js = nullptr;
  cutlab_timeline_stats(t, &js);
  const double v = js ? num(js, "rssKiB") : -1;
  cutlab_free(js);
  cutlab_timeline_close(t);
  return static_cast<int64_t>(v);
}

void test_long_timeline(bool full_export) {
  // Two hours: two halves of a 2-hour recording with a dissolve at 1 h,
  // effects on both, plus many short clips with transitions at the end.
  Plan p(192, 108);
  p.track("v", "video").clip("a", media("long2h.mp4"), 0, 3600 * SEC, 0).clip("b", media("long2h.mp4"), 3600 * SEC, 3500 * SEC, 3600 * SEC);
  const char* kinds[] = {"dissolve", "wipe", "slide", "dip_black", "zoom_in", "zoom_out", "blur", "dip_white"};
  for (int i = 0; i < 20; ++i) {
    const std::string id = "s" + std::to_string(i);
    p.clip(id.c_str(), media("long2h.mp4"), 7100 * SEC + i * 5 * SEC, 5 * SEC, 3000 * SEC + i * 60 * SEC);
  }
  p.effect("a", "contrast", "amount=0.3").effect("a", "vignette").effect("b", "filter", "look=5").effect("b", "sharpen");
  p.transition("b", "dissolve", SEC, SEC);
  p.transition("s0", "wipe", SEC, SEC);
  for (int i = 1; i < 20; ++i) p.transition(("s" + std::to_string(i)).c_str(), kinds[i % 8], SEC / 2, SEC / 2, i % 2 ? "up" : "right");
  const int64_t rss0 = rss_kib();
  const auto t0 = std::chrono::steady_clock::now();
  int ok = 0;
  for (int i = 0; i < 24; ++i) ok += render(p, (i * 7199 / 23) * SEC + SEC / 3, 192, 108).ok;
  ok += render(p, 3600 * SEC, 192, 108).ok;
  const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  std::printf("2-hour timeline: 25 composed pictures (random positions) in %.2f s (RSS %lld -> %lld KiB)\n", secs, static_cast<long long>(rss0),
              static_cast<long long>(rss_kib()));
  CHECK(ok == 25);
  CHECK(secs < 30);
  // The preview: play across the 1-hour transition and seek around; memory stays flat.
  cutlab_timeline* t = nullptr;
  CHECK(cutlab_timeline_open(1280, 720, 2, &t) == CUTLAB_OK);
  if (t) {
    cutlab_timeline_set_plan(t, p.text.c_str());
    std::vector<uint8_t> buf(1280 * 720 * 4);
    uint64_t serial = 0;
    auto pump = [&](int ms) {
      int n = 0;
      const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
      while (std::chrono::steady_clock::now() < end) {
        int32_t w = 0, h = 0;
        int64_t pts = 0;
        n += cutlab_timeline_frame(t, &serial, buf.data(), static_cast<int64_t>(buf.size()), &w, &h, &pts);
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
      }
      return n;
    };
    cutlab_timeline_seek(t, 3599 * SEC, 1);
    cutlab_timeline_play(t);
    const int n = pump(2000);
    cutlab_timeline_pause(t);
    std::printf("  after playing across the 1-hour transition: RSS %lld KiB\n", static_cast<long long>(rss_kib()));
    for (int i = 0; i < 40; ++i) {
      cutlab_timeline_seek(t, ((i * 977) % 7190) * SEC, i % 2);
      pump(40);
    }
    cutlab_timeline_seek(t, 7140 * SEC, 1);
    cutlab_timeline_play(t);
    const int n2 = pump(2000);
    char* js = nullptr;
    cutlab_timeline_stats(t, &js);
    const std::string st = js ? js : "";
    cutlab_free(js);
    cutlab_timeline_close(t);
    const int64_t rss1 = rss_kib();
    std::printf("2-hour timeline preview: %d + %d pictures while playing; RSS %lld -> %lld KiB; %s\n", n, n2, static_cast<long long>(rss0),
                static_cast<long long>(rss1), st.c_str());
    CHECK(n >= 30 && n2 >= 30);
    CHECK(str(st, "videoError").empty());
    // (A plain timeline of the same 2-hour file takes about as much: demuxer
    // indexes and decoders; composing adds only small canvases.)
    if (rss0 > 0 && rss1 > 0) CHECK(rss1 - rss0 < 320 * 1024);
  }
  if (full_export) {
    Settings s;
    s.path = out_path("long_effects.mp4");
    s.codec = g_codec;
    s.w = 192;
    s.h = 108;
    s.fps = "24";
    double secs2 = 0;
    const std::string st = run_export(p, s, &secs2);
    std::printf("2-hour export with effects and transitions: %.1f s (%.0f fps): %s\n", secs2, 7200 * 24 / std::max(secs2, 1e-3), st.c_str());
    CHECK(str(st, "state") == "done");
    CHECK(num(st, "framesDone") == 7200 * 24);
    record(s.path, 192, 108, "24", 7200 * 24);
    for (const int64_t at : {3600 * SEC, 7100 * SEC + 5 * SEC * 7, 7195 * SEC}) {
      const Img o = decoded(s.path, at + SEC / 48, 192, 108), want = render(p, at, 192, 108);
      CHECK(o.ok && diff(o, want) < 8);
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
  bool long_export = false;
  for (int i = 1; i < argc; ++i) {
    const std::string a = argv[i];
    if (a == "--quick") g_quick = true;
    if (a == "--long") long_export = true;
  }
  // The best software H.264 encoder in the build, else MPEG-4 Part 2.
  char* js = nullptr;
  if (cutlab_export_encoders(0, &js) == CUTLAB_OK && js) {
    const std::string s = js;
    if (s.find("\"codec\":\"h264\"") == std::string::npos || s.find("\"hardware\":false") == std::string::npos) g_codec = "mpeg4";
    size_t at = 0;
    bool sw264 = false;
    while ((at = s.find("{", at)) != std::string::npos) {
      if (str(s, "codec", at) == "h264" && s.compare(s.find("\"hardware\":", at) + 11, 5, "false") == 0) sw264 = true;
      ++at;
    }
    g_codec = sw264 ? "h264" : "mpeg4";
  }
  cutlab_free(js);
  if (const char* forced = std::getenv("CUTLAB_EXPORT_CODEC")) g_codec = forced;
  std::printf("exports use %s\n", g_codec.c_str());

  if (std::getenv("CUTLAB_FX_ONLY_LONG")) {
    test_long_timeline(long_export);
    std::printf("%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
  }
  test_catalog();
  test_plan_rejects();
  test_each_effect();
  test_multiple_effects();
  test_video_fades();
  test_transitions();
  test_continuity();
  test_preview_matches();
  test_audio_continuity();
  test_export_consistency();
  if (!g_quick) test_long_timeline(long_export);

  std::printf("%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
