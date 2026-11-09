// Picture effects and transitions (internal header).
//
// One implementation used by playback (TimelinePlayer) and export
// (Exporter): the same function, the same parameters, applied to the same
// kind of picture (8-bit RGBA at the output size). Sizes inside effects
// (blur radius, sharpen radius, vignette, wipe edge) are fractions of the
// picture height, so a 720p preview and a 4K export look the same.
#pragma once

#include <condition_variable>
#include <cstdint>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace cutlab::media {

/// An RGBA picture (4 bytes per pixel, rows `stride` bytes apart).
struct Rgba {
  uint8_t* px = nullptr;
  int w = 0;
  int h = 0;
  int stride = 0;
  uint8_t* row(int y) const { return px + static_cast<size_t>(y) * stride; }
};

/// An owned RGBA picture.
struct RgbaBuffer {
  int w = 0;
  int h = 0;
  std::vector<uint8_t> px;
  void resize(int width, int height) {
    w = width;
    h = height;
    px.resize(static_cast<size_t>(width) * height * 4);
  }
  Rgba view() { return Rgba{px.data(), w, h, w * 4}; }
};

/// One effect of a clip, in the order they are applied.
struct TlEffect {
  std::string type;                      // see effect_types()
  std::map<std::string, double> params;  // missing = default
  double get(const std::string& k, double def) const {
    auto it = params.find(k);
    return it == params.end() ? def : it->second;
  }
};

/// The effect types and their parameters with range and default:
/// "type: name=min..max:default, ...". Unknown types are rejected by the plan.
const std::vector<std::string>& effect_types();
bool known_effect(const std::string& type);
struct EffectParamInfo {
  std::string name;
  double lo, hi, def;
};
struct EffectInfo {
  std::string type;
  std::vector<EffectParamInfo> params;
};
const std::vector<EffectInfo>& effect_catalog();
/// Checks the type and parameter names and clamps every value to its range.
/// Returns false (with a message) for an unknown type or parameter.
bool normalize_effect(TlEffect& e, std::string* error);
/// The looks of the "filter" effect, by index (param look=N).
const std::vector<std::string>& filter_looks();

/// Transition types. Overlapping ones show both clips at once and need media
/// beyond the cut (handles); dips go through a colour and need none.
enum class TransitionKind { dissolve, dip_black, dip_white, wipe, slide, zoom_in, zoom_out, blur };
bool parse_transition(const std::string& name, TransitionKind* out);
bool transition_overlaps(TransitionKind k);
enum class Direction { left, right, up, down };
bool parse_direction(const std::string& name, Direction* out);

/// Rows of work shared by a few threads (effects on large pictures).
class WorkPool {
 public:
  static WorkPool& shared();
  explicit WorkPool(unsigned threads);
  ~WorkPool();
  WorkPool(const WorkPool&) = delete;
  WorkPool& operator=(const WorkPool&) = delete;
  /// Runs fn(begin, end) over [0, n) in chunks; returns when all are done.
  void parallel(int n, const std::function<void(int, int)>& fn);
  unsigned threads() const { return static_cast<unsigned>(workers_.size()) + 1; }

 private:
  void loop();
  void run_chunks();
  std::mutex call_mu_;  // one job at a time (player and exporter may share)
  std::mutex mu_;
  std::condition_variable cv_, done_cv_;
  const std::function<void(int, int)>* job_ = nullptr;
  int n_ = 0, next_ = 0, chunk_ = 1, busy_ = 0;
  uint64_t gen_ = 0;
  bool quit_ = false;
  std::vector<std::thread> workers_;
};

/// Applies `effects` in order to the clip's picture: the area (x, y, w, h)
/// of `img` (the letterboxed clip inside the frame). `frame_h` is the height
/// of the whole output frame (sizes are relative to it).
void apply_effects(const std::vector<TlEffect>& effects, Rgba img, int x, int y, int w, int h, int frame_h);

/// out = overlapping transition from a to b at progress p (0..1). All three
/// have the same size; out may not alias a or b. `b` may be modified (the
/// blur transition blurs it in place). Dips are apply_fade on one picture.
void apply_transition(TransitionKind kind, Direction dir, double p, const Rgba& a, Rgba b, Rgba out);

/// Moves the picture towards a grey level `toward` (0 black, 255 white):
/// level 1 = unchanged, 0 = all `toward`.
void apply_fade(Rgba img, double level, int toward = 0);

/// Gaussian-like blur (three box passes) of the area, sigma in pixels.
void blur_area(Rgba img, int x, int y, int w, int h, double sigma);

/// Smooth start and end (motion transitions).
inline double ease(double p) { return p <= 0 ? 0 : p >= 1 ? 1 : p * p * (3 - 2 * p); }

}  // namespace cutlab::media
