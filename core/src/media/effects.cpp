// Picture effects and transitions. See effects.hpp.
//
// Colour effects run as one pass over the clip's pixels: consecutive
// per-channel adjustments (brightness, contrast, exposure, gamma,
// temperature, tint, highlights, shadows, RGB) are folded into one lookup
// table, consecutive colour matrices (saturation, grayscale, sepia) into one
// matrix; vibrance, black & white, filters and vignette are evaluated per
// pixel. Blur and sharpen are separable box filters (three passes ~
// Gaussian), O(1) per pixel whatever the radius. Rows are split over the
// shared WorkPool.
#include "effects.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <sstream>

namespace cutlab::media {

// ------------------------------------------------------------------ pool

WorkPool& WorkPool::shared() {
  static WorkPool pool([] {
    unsigned n = std::thread::hardware_concurrency();
    if (n == 0) n = 2;
    return std::min(8u, n);
  }());
  return pool;
}

WorkPool::WorkPool(unsigned threads) {
  for (unsigned i = 1; i < threads; ++i) workers_.emplace_back([this] { loop(); });
}

WorkPool::~WorkPool() {
  {
    std::lock_guard<std::mutex> lk(mu_);
    quit_ = true;
  }
  cv_.notify_all();
  for (auto& t : workers_) t.join();
}

void WorkPool::run_chunks() {
  for (;;) {
    int b, e;
    const std::function<void(int, int)>* job;
    {
      std::lock_guard<std::mutex> lk(mu_);
      if (!job_ || next_ >= n_) return;
      b = next_;
      e = std::min(n_, b + chunk_);
      next_ = e;
      job = job_;
    }
    (*job)(b, e);
  }
}

void WorkPool::loop() {
  uint64_t seen = 0;
  std::unique_lock<std::mutex> lk(mu_);
  for (;;) {
    cv_.wait(lk, [&] { return quit_ || gen_ != seen; });
    if (quit_) return;
    seen = gen_;
    lk.unlock();
    run_chunks();
    lk.lock();
    if (--busy_ == 0) done_cv_.notify_all();
  }
}

void WorkPool::parallel(int n, const std::function<void(int, int)>& fn) {
  if (n <= 0) return;
  if (workers_.empty() || n < 8) {
    fn(0, n);
    return;
  }
  std::lock_guard<std::mutex> one(call_mu_);
  {
    std::lock_guard<std::mutex> lk(mu_);
    job_ = &fn;
    n_ = n;
    next_ = 0;
    chunk_ = std::max(1, n / static_cast<int>(threads() * 4));
    busy_ = static_cast<int>(workers_.size());
    ++gen_;
  }
  cv_.notify_all();
  run_chunks();
  std::unique_lock<std::mutex> lk(mu_);
  done_cv_.wait(lk, [&] { return busy_ == 0; });
  job_ = nullptr;
}

// ------------------------------------------------------------ catalogue

namespace {

using ParamSpec = EffectParamInfo;
using EffectSpec = EffectInfo;

const std::vector<EffectSpec>& specs() {
  static const std::vector<EffectSpec> s = {
      {"brightness", {{"amount", -1, 1, 0}}},
      {"contrast", {{"amount", -1, 1, 0}}},
      {"saturation", {{"amount", -1, 1, 0}}},
      {"vibrance", {{"amount", -1, 1, 0}}},
      {"exposure", {{"stops", -3, 3, 0}}},
      {"gamma", {{"value", 0.2, 5, 1}}},
      {"temperature", {{"amount", -1, 1, 0}}},
      {"tint", {{"amount", -1, 1, 0}}},
      {"highlights", {{"amount", -1, 1, 0}}},
      {"shadows", {{"amount", -1, 1, 0}}},
      {"sharpen", {{"amount", 0, 3, 0.6}, {"radius", 0.0005, 0.01, 0.0015}}},
      {"blur", {{"radius", 0, 0.05, 0.006}}},
      {"vignette", {{"amount", 0, 1, 0.5}, {"size", 0.2, 1.5, 0.75}, {"softness", 0.05, 1, 0.45}}},
      {"grayscale", {{"amount", 0, 1, 1}}},
      {"black_white", {{"threshold", 0, 1, 0.5}, {"softness", 0, 0.5, 0.04}}},
      {"sepia", {{"amount", 0, 1, 1}}},
      {"rgb",
       {{"red", 0, 2, 1},
        {"green", 0, 2, 1},
        {"blue", 0, 2, 1},
        {"red_offset", -0.5, 0.5, 0},
        {"green_offset", -0.5, 0.5, 0},
        {"blue_offset", -0.5, 0.5, 0}}},
      {"filter", {{"look", 0, 7, 0}, {"amount", 0, 1, 1}}},
  };
  return s;
}

const EffectSpec* spec_of(const std::string& type) {
  for (const auto& s : specs())
    if (s.type == type) return &s;
  return nullptr;
}

double param(const TlEffect& e, const char* name) {
  const EffectSpec* s = spec_of(e.type);
  double def = 0;
  if (s)
    for (const auto& p : s->params)
      if (p.name == name) def = p.def;
  return e.get(name, def);
}

}  // namespace

const std::vector<EffectInfo>& effect_catalog() { return specs(); }

const std::vector<std::string>& effect_types() {
  static const std::vector<std::string> v = [] {
    std::vector<std::string> out;
    for (const auto& s : specs()) {
      std::ostringstream os;
      os << s.type << ":";
      for (size_t i = 0; i < s.params.size(); ++i)
        os << (i ? ", " : " ") << s.params[i].name << "=" << s.params[i].lo << ".." << s.params[i].hi << ":"
           << s.params[i].def;
      out.push_back(os.str());
    }
    return out;
  }();
  return v;
}

bool known_effect(const std::string& type) { return spec_of(type) != nullptr; }

const std::vector<std::string>& filter_looks() {
  static const std::vector<std::string> v = {"teal_orange", "warm", "cool", "vintage", "noir", "vivid", "bleach", "matte"};
  return v;
}

bool normalize_effect(TlEffect& e, std::string* error) {
  const EffectSpec* s = spec_of(e.type);
  if (!s) {
    if (error) *error = "unknown effect " + e.type;
    return false;
  }
  for (auto& [k, v] : e.params) {
    const ParamSpec* p = nullptr;
    for (const auto& ps : s->params)
      if (ps.name == k) p = &ps;
    if (!p) {
      if (error) *error = "unknown parameter " + k + " of " + e.type;
      return false;
    }
    if (!std::isfinite(v)) v = p->def;
    v = std::clamp(v, p->lo, p->hi);
  }
  if (e.type == "filter") e.params["look"] = std::round(param(e, "look"));
  return true;
}

bool parse_transition(const std::string& n, TransitionKind* out) {
  static const std::pair<const char*, TransitionKind> names[] = {
      {"dissolve", TransitionKind::dissolve}, {"dip_black", TransitionKind::dip_black},
      {"dip_white", TransitionKind::dip_white}, {"wipe", TransitionKind::wipe},
      {"slide", TransitionKind::slide},       {"zoom_in", TransitionKind::zoom_in},
      {"zoom_out", TransitionKind::zoom_out}, {"blur", TransitionKind::blur}};
  for (const auto& [name, k] : names)
    if (n == name) {
      *out = k;
      return true;
    }
  return false;
}

bool transition_overlaps(TransitionKind k) { return k != TransitionKind::dip_black && k != TransitionKind::dip_white; }

bool parse_direction(const std::string& n, Direction* out) {
  if (n == "left") *out = Direction::left;
  else if (n == "right") *out = Direction::right;
  else if (n == "up") *out = Direction::up;
  else if (n == "down") *out = Direction::down;
  else return false;
  return true;
}

// --------------------------------------------------------------- colour

namespace {

constexpr float kR = 0.2126f, kG = 0.7152f, kB = 0.0722f;  // Rec. 709 luma

inline double clamp01(double v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
inline float clampf(float v) { return v < 0.f ? 0.f : v > 1.f ? 1.f : v; }
inline float smooth(float e0, float e1, float x) {
  if (e1 <= e0) return x < e0 ? 0.f : 1.f;
  float t = clampf((x - e0) / (e1 - e0));
  return t * t * (3 - 2 * t);
}

bool separable(const std::string& t) {
  return t == "brightness" || t == "contrast" || t == "exposure" || t == "gamma" || t == "temperature" ||
         t == "tint" || t == "highlights" || t == "shadows" || t == "rgb";
}
bool is_matrix(const std::string& t) { return t == "saturation" || t == "grayscale" || t == "sepia"; }
bool spatial(const std::string& t) { return t == "blur" || t == "sharpen"; }

// One channel (0 r, 1 g, 2 b) through a per-channel adjustment.
double channel_fn(const TlEffect& e, int ch, double v) {
  const std::string& t = e.type;
  if (t == "brightness") return clamp01(v + param(e, "amount") * 0.4);
  if (t == "contrast") {
    double a = param(e, "amount");
    double f = a >= 0 ? 1 + a * 2 : 1 + a;
    return clamp01((v - 0.5) * f + 0.5);
  }
  if (t == "exposure") return clamp01(std::pow(std::pow(v, 2.2) * std::pow(2.0, param(e, "stops")), 1 / 2.2));
  if (t == "gamma") return clamp01(std::pow(v, 1 / param(e, "value")));
  if (t == "temperature") {
    double a = param(e, "amount");
    return clamp01(ch == 0 ? v * (1 + 0.25 * a) : ch == 2 ? v * (1 - 0.25 * a) : v);
  }
  if (t == "tint") {  // positive = magenta, negative = green
    double a = param(e, "amount");
    return clamp01(ch == 1 ? v * (1 - 0.2 * a) : v * (1 + 0.08 * a));
  }
  if (t == "highlights") {
    double k = clamp01((v - 0.5) / 0.5);
    return clamp01(v + param(e, "amount") * 0.35 * k * (1 - 0.5 * k));
  }
  if (t == "shadows") {
    double k = clamp01((0.5 - v) / 0.5);
    return clamp01(v + param(e, "amount") * 0.35 * k * (1 - 0.5 * k));
  }
  if (t == "rgb") {
    static const char* g[] = {"red", "green", "blue"};
    static const char* o[] = {"red_offset", "green_offset", "blue_offset"};
    return clamp01(v * param(e, g[ch]) + param(e, o[ch]));
  }
  return v;
}

using Mat = std::array<float, 12>;  // 3x3 + offset column (rows: r, g, b)

Mat identity() { return {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0}; }
Mat mix(const Mat& a, const Mat& b, float t) {
  Mat m;
  for (int i = 0; i < 12; ++i) m[i] = a[i] + (b[i] - a[i]) * t;
  return m;
}
Mat luma_mat() { return {kR, kG, kB, 0, kR, kG, kB, 0, kR, kG, kB, 0}; }
Mat mul(const Mat& second, const Mat& first) {  // second(first(x))
  Mat m{};
  for (int r = 0; r < 3; ++r) {
    for (int c = 0; c < 3; ++c)
      m[r * 4 + c] = second[r * 4] * first[c] + second[r * 4 + 1] * first[4 + c] + second[r * 4 + 2] * first[8 + c];
    m[r * 4 + 3] = second[r * 4] * first[3] + second[r * 4 + 1] * first[7] + second[r * 4 + 2] * first[11] +
                   second[r * 4 + 3];
  }
  return m;
}
Mat matrix_of(const TlEffect& e) {
  if (e.type == "saturation") return mix(luma_mat(), identity(), static_cast<float>(1 + param(e, "amount")));
  if (e.type == "grayscale") return mix(identity(), luma_mat(), static_cast<float>(param(e, "amount")));
  // sepia
  Mat sep = {0.393f, 0.769f, 0.189f, 0, 0.349f, 0.686f, 0.168f, 0, 0.272f, 0.534f, 0.131f, 0};
  return mix(identity(), sep, static_cast<float>(param(e, "amount")));
}

constexpr int kLut = 4096;

struct Step {
  enum Kind { lut, matrix, vibrance, bw, look, vignette } kind;
  std::array<std::vector<float>, 3> table;  // lut
  Mat m{};                                  // matrix
  float a = 0, b = 0, c = 0;                // parameters
  int look_index = 0;
};

inline void apply_mat(const Mat& m, float& r, float& g, float& b) {
  float nr = m[0] * r + m[1] * g + m[2] * b + m[3];
  float ng = m[4] * r + m[5] * g + m[6] * b + m[7];
  float nb = m[8] * r + m[9] * g + m[10] * b + m[11];
  r = clampf(nr);
  g = clampf(ng);
  b = clampf(nb);
}

inline void sat_contrast(float& r, float& g, float& b, float sat, float con) {
  float l = kR * r + kG * g + kB * b;
  r = clampf(((l + (r - l) * sat) - 0.5f) * con + 0.5f);
  g = clampf(((l + (g - l) * sat) - 0.5f) * con + 0.5f);
  b = clampf(((l + (b - l) * sat) - 0.5f) * con + 0.5f);
}

void apply_look(int look, float amount, float& r, float& g, float& b) {
  float r0 = r, g0 = g, b0 = b;
  switch (look) {
    case 0: {  // teal & orange: teal shadows, warm highlights
      float l = kR * r + kG * g + kB * b;
      r = clampf(r - 0.07f * (1 - l) + 0.09f * l);
      g = clampf(g + 0.01f * (1 - l) + 0.02f * l);
      b = clampf(b + 0.08f * (1 - l) - 0.08f * l);
      sat_contrast(r, g, b, 1.1f, 1.1f);
      break;
    }
    case 1:  // warm
      r = clampf(r * 1.08f + 0.02f);
      g = clampf(g * 1.02f);
      b = clampf(b * 0.88f);
      break;
    case 2:  // cool
      r = clampf(r * 0.9f);
      g = clampf(g * 1.0f + 0.01f);
      b = clampf(b * 1.1f + 0.02f);
      break;
    case 3: {  // vintage: faded, warm, less saturated
      Mat sep = {0.393f, 0.769f, 0.189f, 0, 0.349f, 0.686f, 0.168f, 0, 0.272f, 0.534f, 0.131f, 0};
      apply_mat(mix(identity(), sep, 0.3f), r, g, b);
      sat_contrast(r, g, b, 0.8f, 0.9f);
      r = 0.08f + r * 0.86f;
      g = 0.06f + g * 0.86f;
      b = 0.05f + b * 0.82f;
      break;
    }
    case 4: {  // noir: high-contrast monochrome
      float l = kR * r + kG * g + kB * b;
      r = g = b = clampf((l - 0.5f) * 1.4f + 0.5f);
      break;
    }
    case 5: sat_contrast(r, g, b, 1.35f, 1.08f); break;  // vivid
    case 6: sat_contrast(r, g, b, 0.55f, 1.25f); break;  // bleach bypass
    case 7:                                              // matte: lifted blacks
      sat_contrast(r, g, b, 0.9f, 0.95f);
      r = 0.09f + r * 0.86f;
      g = 0.09f + g * 0.86f;
      b = 0.1f + b * 0.85f;
      break;
    default: break;
  }
  r = r0 + (r - r0) * amount;
  g = g0 + (g - g0) * amount;
  b = b0 + (b - b0) * amount;
}

// Builds the point steps for effects[from, to) (none of them spatial).
std::vector<Step> build_steps(const std::vector<TlEffect>& fx, size_t from, size_t to) {
  std::vector<Step> steps;
  size_t i = from;
  while (i < to) {
    const TlEffect& e = fx[i];
    if (separable(e.type)) {
      size_t j = i;
      while (j < to && separable(fx[j].type)) ++j;
      Step s{Step::lut, {}, {}, 0, 0, 0, 0};
      for (int ch = 0; ch < 3; ++ch) {
        s.table[ch].resize(kLut);
        for (int k = 0; k < kLut; ++k) {
          double v = static_cast<double>(k) / (kLut - 1);
          for (size_t q = i; q < j; ++q) v = channel_fn(fx[q], ch, v);
          s.table[ch][k] = static_cast<float>(v);
        }
      }
      steps.push_back(std::move(s));
      i = j;
    } else if (is_matrix(e.type)) {
      Mat m = identity();
      size_t j = i;
      while (j < to && is_matrix(fx[j].type)) m = mul(matrix_of(fx[j++]), m);
      Step s{Step::matrix, {}, m, 0, 0, 0, 0};
      steps.push_back(std::move(s));
      i = j;
    } else {
      Step s{Step::vibrance, {}, {}, 0, 0, 0, 0};
      if (e.type == "vibrance") {
        s.a = static_cast<float>(param(e, "amount"));
      } else if (e.type == "black_white") {
        s.kind = Step::bw;
        s.a = static_cast<float>(param(e, "threshold"));
        s.b = static_cast<float>(param(e, "softness"));
      } else if (e.type == "filter") {
        s.kind = Step::look;
        s.look_index = static_cast<int>(param(e, "look"));
        s.a = static_cast<float>(param(e, "amount"));
      } else if (e.type == "vignette") {
        s.kind = Step::vignette;
        s.a = static_cast<float>(param(e, "amount"));
        s.b = static_cast<float>(param(e, "size"));
        s.c = static_cast<float>(param(e, "softness"));
      }
      steps.push_back(std::move(s));
      ++i;
    }
  }
  return steps;
}

inline float lut(const std::vector<float>& t, float v) { return t[static_cast<int>(v * (kLut - 1) + 0.5f)]; }

void run_steps(const std::vector<Step>& steps, Rgba img, int x0, int y0, int w, int h) {
  if (steps.empty()) return;
  // Only per-channel adjustments: 8-bit tables, the fast path.
  if (steps.size() == 1 && steps[0].kind == Step::lut) {
    std::array<std::array<uint8_t, 256>, 3> t8;
    for (int ch = 0; ch < 3; ++ch)
      for (int k = 0; k < 256; ++k) t8[ch][k] = static_cast<uint8_t>(lut(steps[0].table[ch], k / 255.f) * 255.f + 0.5f);
    WorkPool::shared().parallel(h, [&](int b, int e) {
      for (int y = b; y < e; ++y) {
        uint8_t* p = img.row(y0 + y) + x0 * 4;
        for (int x = 0; x < w; ++x, p += 4) {
          p[0] = t8[0][p[0]];
          p[1] = t8[1][p[1]];
          p[2] = t8[2][p[2]];
        }
      }
    });
    return;
  }
  const float cx = w * 0.5f, cy = h * 0.5f;
  WorkPool::shared().parallel(h, [&](int b, int e) {
    for (int y = b; y < e; ++y) {
      uint8_t* p = img.row(y0 + y) + x0 * 4;
      const float ny = (y + 0.5f - cy) / cy;
      for (int x = 0; x < w; ++x, p += 4) {
        float r = p[0] / 255.f, g = p[1] / 255.f, bl = p[2] / 255.f;
        for (const Step& s : steps) {
          switch (s.kind) {
            case Step::lut:
              r = lut(s.table[0], r);
              g = lut(s.table[1], g);
              bl = lut(s.table[2], bl);
              break;
            case Step::matrix: apply_mat(s.m, r, g, bl); break;
            case Step::vibrance: {
              float mx = std::max(r, std::max(g, bl)), mn = std::min(r, std::min(g, bl));
              float l = kR * r + kG * g + kB * bl;
              float k = 1 + s.a * (1 - (mx - mn));
              r = clampf(l + (r - l) * k);
              g = clampf(l + (g - l) * k);
              bl = clampf(l + (bl - l) * k);
              break;
            }
            case Step::bw: {
              float l = kR * r + kG * g + kB * bl;
              r = g = bl = smooth(s.a - s.b, s.a + s.b, l);
              break;
            }
            case Step::look: apply_look(s.look_index, s.a, r, g, bl); break;
            case Step::vignette: {
              float nx = (x + 0.5f - cx) / cx;
              float d = std::sqrt(nx * nx + ny * ny);
              float f = 1 - s.a * smooth(s.b, s.b + s.c, d);
              r *= f;
              g *= f;
              bl *= f;
              break;
            }
          }
        }
        p[0] = static_cast<uint8_t>(r * 255.f + 0.5f);
        p[1] = static_cast<uint8_t>(g * 255.f + 0.5f);
        p[2] = static_cast<uint8_t>(bl * 255.f + 0.5f);
      }
    }
  });
}

// ----------------------------------------------------------------- blur

// Scratch memory per calling thread (player and exporter run separately),
// reused between frames so effects do not allocate per frame.
std::vector<uint8_t>& scratch(int which) {
  thread_local std::vector<uint8_t> s[3];
  return s[which];
}

constexpr int kBlurBand = 128;  // columns per vertical-pass job

// One box pass, horizontal then vertical, radius r, of the area of img;
// tmp holds w*h*4 bytes. Division by the window is a multiply (16.16).
void box_pass(Rgba img, int x0, int y0, int w, int h, int r, uint8_t* tmp) {
  const uint32_t win = static_cast<uint32_t>(2 * r + 1);
  const uint32_t inv = (1u << 24) / win + 1;  // sum * inv >> 24 = sum / win (sum <= 255 * win)
  auto div = [inv](uint32_t sum) { return static_cast<uint8_t>((sum * static_cast<uint64_t>(inv) + (1u << 23)) >> 24); };
  // Horizontal: img -> tmp.
  WorkPool::shared().parallel(h, [&](int b, int e) {
    for (int y = b; y < e; ++y) {
      const uint8_t* src = img.row(y0 + y) + x0 * 4;
      uint8_t* dst = tmp + static_cast<size_t>(y) * w * 4;
      uint32_t sr = 0, sg = 0, sb = 0;
      for (int k = -r; k <= r; ++k) {
        const uint8_t* q = src + std::clamp(k, 0, w - 1) * 4;
        sr += q[0];
        sg += q[1];
        sb += q[2];
      }
      for (int x = 0; x < w; ++x) {
        uint8_t* d = dst + x * 4;
        d[0] = div(sr);
        d[1] = div(sg);
        d[2] = div(sb);
        d[3] = 255;
        const uint8_t* add = src + std::min(x + r + 1, w - 1) * 4;
        const uint8_t* sub = src + std::max(x - r, 0) * 4;
        sr += add[0] - sub[0];
        sg += add[1] - sub[1];
        sb += add[2] - sub[2];
      }
    }
  });
  // Vertical: tmp -> img, in bands of columns (running sums per column).
  const int bands = (w + kBlurBand - 1) / kBlurBand;
  WorkPool::shared().parallel(bands, [&](int b, int e) {
    uint32_t sum[kBlurBand * 4];
    for (int bi = b; bi < e; ++bi) {
      const int xa = bi * kBlurBand, n = std::min(w, xa + kBlurBand) - xa;
      std::fill(sum, sum + n * 4, 0u);
      for (int k = -r; k <= r; ++k) {
        const uint8_t* row = tmp + static_cast<size_t>(std::clamp(k, 0, h - 1)) * w * 4 + xa * 4;
        for (int i = 0; i < n * 4; ++i) sum[i] += row[i];
      }
      for (int y = 0; y < h; ++y) {
        uint8_t* out = img.row(y0 + y) + (x0 + xa) * 4;
        const uint8_t* add = tmp + static_cast<size_t>(std::min(y + r + 1, h - 1)) * w * 4 + xa * 4;
        const uint8_t* sub = tmp + static_cast<size_t>(std::max(y - r, 0)) * w * 4 + xa * 4;
        for (int i = 0; i < n * 4; ++i) {
          out[i] = div(sum[i]);
          sum[i] += add[i] - sub[i];
        }
      }
    }
  });
}

void blur_direct(Rgba img, int x, int y, int w, int h, double sigma, uint8_t* tmp) {
  // Three box passes of width wb: variance 3 * (wb^2 - 1) / 12 = sigma^2.
  int wb = static_cast<int>(std::lround(std::sqrt(4 * sigma * sigma + 1)));
  int r = std::max(1, (wb - 1) / 2);
  r = std::min(r, std::max(1, std::min(w, h) / 2));
  for (int i = 0; i < 3; ++i) box_pass(img, x, y, w, h, r, tmp);
}

void blur_with(Rgba img, int x0, int y0, int w, int h, double sigma, uint8_t* tmp) {
  if (w <= 0 || h <= 0 || sigma < 0.5) return;
  // Large blurs are done on a picture 2, 4 or 8 times smaller and scaled
  // back up (the blurred picture has no detail that the smaller one loses):
  // the same look at a fraction of the cost, whatever the frame size.
  int f = 1;
  while (f < 8 && sigma / (f * 2) >= 2.0 && w / (f * 2) >= 8 && h / (f * 2) >= 8) f *= 2;
  if (f == 1) {
    blur_direct(img, x0, y0, w, h, sigma, tmp);
    return;
  }
  const int sw = (w + f - 1) / f, sh = (h + f - 1) / f;
  auto& small = scratch(2);
  small.resize(static_cast<size_t>(sw) * sh * 4);
  // Box-average f x f blocks.
  WorkPool::shared().parallel(sh, [&](int b, int e) {
    for (int sy = b; sy < e; ++sy) {
      const int ya = sy * f, yb = std::min(h, ya + f);
      for (int sx = 0; sx < sw; ++sx) {
        const int xa = sx * f, xb = std::min(w, xa + f);
        uint32_t acc[3] = {0, 0, 0};
        for (int yy = ya; yy < yb; ++yy) {
          const uint8_t* p = img.row(y0 + yy) + (x0 + xa) * 4;
          for (int xx = xa; xx < xb; ++xx, p += 4) {
            acc[0] += p[0];
            acc[1] += p[1];
            acc[2] += p[2];
          }
        }
        const uint32_t cnt = static_cast<uint32_t>((yb - ya) * (xb - xa));
        uint8_t* d = small.data() + (static_cast<size_t>(sy) * sw + sx) * 4;
        for (int c = 0; c < 3; ++c) d[c] = static_cast<uint8_t>((acc[c] + cnt / 2) / cnt);
        d[3] = 255;
      }
    }
  });
  Rgba sm{small.data(), sw, sh, sw * 4};
  blur_direct(sm, 0, 0, sw, sh, sigma / f, tmp);
  // Bilinear back to full size (pixel centres line up).
  std::vector<int> x_lo(static_cast<size_t>(w)), x_w(static_cast<size_t>(w));
  for (int x = 0; x < w; ++x) {
    const double fx = std::clamp((x + 0.5) / f - 0.5, 0.0, sw - 1.0);
    x_lo[x] = std::min(static_cast<int>(fx), sw - 1);
    x_w[x] = static_cast<int>((fx - x_lo[x]) * 256 + 0.5);
  }
  WorkPool::shared().parallel(h, [&](int b, int e) {
    for (int y = b; y < e; ++y) {
      const double fy = std::clamp((y + 0.5) / f - 0.5, 0.0, sh - 1.0);
      const int ylo = std::min(static_cast<int>(fy), sh - 1), yhi = std::min(ylo + 1, sh - 1);
      const int wy = static_cast<int>((fy - ylo) * 256 + 0.5);
      const uint8_t* r0 = small.data() + static_cast<size_t>(ylo) * sw * 4;
      const uint8_t* r1 = small.data() + static_cast<size_t>(yhi) * sw * 4;
      uint8_t* out = img.row(y0 + y) + x0 * 4;
      for (int x = 0; x < w; ++x) {
        const int xl = x_lo[x], xh = std::min(xl + 1, sw - 1), wx = x_w[x];
        for (int c = 0; c < 3; ++c) {
          const int top = r0[xl * 4 + c] * (256 - wx) + r0[xh * 4 + c] * wx;
          const int bot = r1[xl * 4 + c] * (256 - wx) + r1[xh * 4 + c] * wx;
          out[x * 4 + c] = static_cast<uint8_t>((top * (256 - wy) + bot * wy + 32768) >> 16);
        }
      }
    }
  });
}

}  // namespace

void blur_area(Rgba img, int x, int y, int w, int h, double sigma) {
  auto& tmp = scratch(0);
  tmp.resize(static_cast<size_t>(w) * h * 4);
  blur_with(img, x, y, w, h, sigma, tmp.data());
}

void apply_effects(const std::vector<TlEffect>& fx, Rgba img, int x, int y, int w, int h, int frame_h) {
  if (fx.empty() || w <= 0 || h <= 0) return;
  size_t i = 0;
  while (i < fx.size()) {
    if (!spatial(fx[i].type)) {
      size_t j = i;
      while (j < fx.size() && !spatial(fx[j].type)) ++j;
      run_steps(build_steps(fx, i, j), img, x, y, w, h);
      i = j;
      continue;
    }
    const TlEffect& e = fx[i++];
    const size_t bytes = static_cast<size_t>(w) * h * 4;
    auto& tmp = scratch(0);
    tmp.resize(bytes);
    if (e.type == "blur") {
      blur_with(img, x, y, w, h, param(e, "radius") * frame_h, tmp.data());
    } else {  // sharpen: unsharp mask
      double amount = param(e, "amount");
      if (amount <= 0) continue;
      auto& copy = scratch(1);
      copy.resize(bytes);
      for (int row = 0; row < h; ++row) std::memcpy(copy.data() + static_cast<size_t>(row) * w * 4, img.row(y + row) + x * 4, w * 4);
      Rgba soft{copy.data(), w, h, w * 4};
      blur_with(soft, 0, 0, w, h, std::max(0.5, param(e, "radius") * frame_h), tmp.data());
      const int k = static_cast<int>(amount * 256);
      WorkPool::shared().parallel(h, [&](int b, int en) {
        for (int row = b; row < en; ++row) {
          uint8_t* p = img.row(y + row) + x * 4;
          const uint8_t* s = copy.data() + static_cast<size_t>(row) * w * 4;
          for (int q = 0; q < w; ++q, p += 4, s += 4) {
            for (int c = 0; c < 3; ++c) {
              const int v = p[c] + ((p[c] - s[c]) * k >> 8);
              p[c] = static_cast<uint8_t>(v < 0 ? 0 : v > 255 ? 255 : v);
            }
          }
        }
      });
    }
  }
}

// ---------------------------------------------------------- transitions

void apply_fade(Rgba img, double level, int toward) {
  if (level >= 1) return;
  const int k = static_cast<int>(std::clamp(level, 0.0, 1.0) * 256 + 0.5);
  const int base = toward * (256 - k);
  WorkPool::shared().parallel(img.h, [&](int b, int e) {
    for (int y = b; y < e; ++y) {
      uint8_t* p = img.row(y);
      for (int x = 0; x < img.w * 4; ++x) {
        if ((x & 3) == 3) continue;
        p[x] = static_cast<uint8_t>((p[x] * k + base + 128) >> 8);
      }
    }
  });
}

namespace {

void dissolve(const Rgba& a, const Rgba& b, Rgba out, double p) {
  const int k = static_cast<int>(std::clamp(p, 0.0, 1.0) * 256 + 0.5);
  WorkPool::shared().parallel(out.h, [&](int y0, int y1) {
    for (int y = y0; y < y1; ++y) {
      const uint8_t* pa = a.row(y);
      const uint8_t* pb = b.row(y);
      uint8_t* po = out.row(y);
      for (int x = 0; x < out.w * 4; ++x) po[x] = static_cast<uint8_t>((pa[x] * (256 - k) + pb[x] * k + 128) >> 8);
    }
  });
}

// Where output column/row i samples a picture scaled by s about the centre:
// lower index, weight of the next one (0..256), inside the picture.
struct Axis {
  std::vector<int> lo, wt;
  std::vector<uint8_t> in;
  void build(int n, float s) {
    lo.resize(n);
    wt.resize(n);
    in.resize(n);
    const float c = (n - 1) * 0.5f;
    for (int i = 0; i < n; ++i) {
      float f = c + (i - c) / s;
      in[i] = f >= -0.5f && f <= n - 0.5f;
      f = std::clamp(f, 0.f, n - 1.f);
      lo[i] = std::min(static_cast<int>(f), n - 1);
      wt[i] = static_cast<int>((f - lo[i]) * 256 + 0.5f);
    }
  }
};

inline void bilerp(const Rgba& img, const Axis& ax, const Axis& ay, int x, int y, int* rgb) {
  const int xl = ax.lo[x], xh = std::min(xl + 1, img.w - 1), wx = ax.wt[x];
  const int yl = ay.lo[y], yh = std::min(yl + 1, img.h - 1), wy = ay.wt[y];
  const uint8_t* r0 = img.row(yl);
  const uint8_t* r1 = img.row(yh);
  for (int c = 0; c < 3; ++c) {
    const int top = r0[xl * 4 + c] * (256 - wx) + r0[xh * 4 + c] * wx;
    const int bot = r1[xl * 4 + c] * (256 - wx) + r1[xh * 4 + c] * wx;
    rgb[c] = (top * (256 - wy) + bot * wy + 128) >> 8;  // x256
  }
}

// out = over (scaled by so about the centre, opacity alpha) on under (scaled by su).
void zoom(const Rgba& under, float su, const Rgba& over, float so, float alpha, Rgba out) {
  Axis ux, uy, ox, oy;
  ux.build(out.w, su);
  uy.build(out.h, su);
  ox.build(out.w, so);
  oy.build(out.h, so);
  const int ka = static_cast<int>(std::clamp(alpha, 0.f, 1.f) * 256 + 0.5f);
  WorkPool::shared().parallel(out.h, [&](int y0, int y1) {
    int u[3], o[3];
    for (int y = y0; y < y1; ++y) {
      uint8_t* po = out.row(y);
      const bool urow = uy.in[y], orow = oy.in[y];
      for (int x = 0; x < out.w; ++x) {
        if (urow && ux.in[x]) {
          bilerp(under, ux, uy, x, y, u);
        } else {
          u[0] = u[1] = u[2] = 0;
        }
        const int k = (orow && ox.in[x]) ? ka : 0;
        if (k) {
          bilerp(over, ox, oy, x, y, o);
          for (int c = 0; c < 3; ++c) po[x * 4 + c] = static_cast<uint8_t>(((u[c] * (256 - k) + o[c] * k) + 32768) >> 16);
        } else {
          for (int c = 0; c < 3; ++c) po[x * 4 + c] = static_cast<uint8_t>((u[c] + 128) >> 8);
        }
        po[x * 4 + 3] = 255;
      }
    }
  });
}

}  // namespace

void apply_transition(TransitionKind kind, Direction dir, double p, const Rgba& a, Rgba b, Rgba out) {
  p = std::clamp(p, 0.0, 1.0);
  const int w = out.w, h = out.h;
  switch (kind) {
    case TransitionKind::dissolve: dissolve(a, b, out, p); return;
    case TransitionKind::dip_black:
    case TransitionKind::dip_white: {  // normally done with apply_fade
      const int toward = kind == TransitionKind::dip_white ? 255 : 0;
      const Rgba& src = p < 0.5 ? a : b;
      for (int y = 0; y < h; ++y) std::memcpy(out.row(y), src.row(y), static_cast<size_t>(w) * 4);
      apply_fade(out, std::abs(1 - 2 * p), toward);
      return;
    }
    case TransitionKind::wipe: {
      const bool horizontal = dir == Direction::left || dir == Direction::right;
      const int len = horizontal ? w : h;
      const float soft = std::max(1.f, 0.015f * h);
      const float pos = static_cast<float>((1 - p) * (len + soft) - soft);  // B where coordinate > pos
      WorkPool::shared().parallel(h, [&](int y0, int y1) {
        for (int y = y0; y < y1; ++y) {
          const uint8_t* pa = a.row(y);
          const uint8_t* pb = b.row(y);
          uint8_t* po = out.row(y);
          for (int x = 0; x < w; ++x) {
            // left: edge moves right-to-left; up: bottom-to-top.
            int c = dir == Direction::left ? x : dir == Direction::right ? w - 1 - x : dir == Direction::up ? y : h - 1 - y;
            float al = std::clamp((c + 0.5f - pos) / soft, 0.f, 1.f);
            int k = static_cast<int>(al * 256 + 0.5f);
            for (int ch = 0; ch < 4; ++ch)
              po[x * 4 + ch] = static_cast<uint8_t>((pa[x * 4 + ch] * (256 - k) + pb[x * 4 + ch] * k + 128) >> 8);
          }
        }
      });
      (void)len;
      return;
    }
    case TransitionKind::slide: {  // B pushes A out
      const double e = ease(p);
      if (dir == Direction::left || dir == Direction::right) {
        const int off = static_cast<int>(std::lround(e * w));
        WorkPool::shared().parallel(h, [&](int y0, int y1) {
          for (int y = y0; y < y1; ++y) {
            uint8_t* po = out.row(y);
            if (dir == Direction::left) {  // B enters from the right
              std::memcpy(po, a.row(y) + static_cast<size_t>(off) * 4, static_cast<size_t>(w - off) * 4);
              std::memcpy(po + static_cast<size_t>(w - off) * 4, b.row(y), static_cast<size_t>(off) * 4);
            } else {  // B enters from the left
              std::memcpy(po, b.row(y) + static_cast<size_t>(w - off) * 4, static_cast<size_t>(off) * 4);
              std::memcpy(po + static_cast<size_t>(off) * 4, a.row(y), static_cast<size_t>(w - off) * 4);
            }
          }
        });
      } else {
        const int off = static_cast<int>(std::lround(e * h));
        WorkPool::shared().parallel(h, [&](int y0, int y1) {
          for (int y = y0; y < y1; ++y) {
            const uint8_t* src;
            if (dir == Direction::up)  // B enters from the bottom
              src = y < h - off ? a.row(y + off) : b.row(y - (h - off));
            else  // B enters from the top
              src = y < off ? b.row(y + (h - off)) : a.row(y - off);
            std::memcpy(out.row(y), src, static_cast<size_t>(w) * 4);
          }
        });
      }
      return;
    }
    case TransitionKind::zoom_in: {  // A grows and fades into B growing to full size
      const float e = static_cast<float>(ease(p));
      zoom(a, 1 + 0.5f * e, b, 0.75f + 0.25f * e, e, out);
      return;
    }
    case TransitionKind::zoom_out: {  // A shrinks away over B settling from large
      const float e = static_cast<float>(ease(p));
      zoom(b, 1.5f - 0.5f * e, a, 1 - 0.25f * e, 1 - e, out);
      return;
    }
    case TransitionKind::blur: {  // both blurred, most at the middle, dissolved
      const double sigma = std::sin(p * 3.14159265358979) * 0.02 * h;
      for (int y = 0; y < h; ++y) std::memcpy(out.row(y), a.row(y), static_cast<size_t>(w) * 4);
      blur_area(out, 0, 0, w, h, sigma);
      blur_area(b, 0, 0, w, h, sigma);
      dissolve(out, b, out, p);
      return;
    }
  }
}

}  // namespace cutlab::media
