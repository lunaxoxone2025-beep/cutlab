// Cost of the picture effects and transitions per frame at gaming sizes
// (1080p, 1440p, 4K), on this machine's CPU with the shared worker pool.
// Links the effects code directly (no FFmpeg): only the effect math is
// timed, not decoding or encoding.
//
//   cutlab_bench_effects [frames-per-measurement]
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "effects.hpp"

using namespace cutlab::media;

namespace {

void fill(RgbaBuffer& b, unsigned seed) {
  // A busy picture (gradients and noise), like game footage.
  uint32_t s = seed;
  for (int y = 0; y < b.h; ++y) {
    uint8_t* p = b.px.data() + static_cast<size_t>(y) * b.w * 4;
    for (int x = 0; x < b.w; ++x, p += 4) {
      s = s * 1664525u + 1013904223u;
      p[0] = static_cast<uint8_t>((x * 255 / b.w + (s >> 28)) & 255);
      p[1] = static_cast<uint8_t>((y * 255 / b.h + (s >> 26)) & 255);
      p[2] = static_cast<uint8_t>(((x + y) * 128 / b.w + (s >> 27)) & 255);
      p[3] = 255;
    }
  }
}

template <class F>
double ms_per(int frames, F&& f) {
  f();  // warm up (scratch buffers, tables)
  const auto t0 = std::chrono::steady_clock::now();
  for (int i = 0; i < frames; ++i) f();
  return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count() / frames;
}

}  // namespace

int main(int argc, char** argv) {
  const int frames = argc > 1 ? std::max(1, std::atoi(argv[1])) : 10;
  std::printf("worker threads: %u\n", WorkPool::shared().threads());
  struct Size {
    const char* name;
    int w, h;
  } sizes[] = {{"1080p", 1920, 1080}, {"1440p", 2560, 1440}, {"4K", 3840, 2160}};
  struct Fx {
    const char* name;
    std::vector<TlEffect> list;
  };
  auto e = [](const char* type, std::map<std::string, double> p = {}) { return TlEffect{type, std::move(p)}; };
  const std::vector<Fx> effects = {
      {"brightness+contrast (lookup table)", {e("brightness", {{"amount", 0.1}}), e("contrast", {{"amount", 0.2}})}},
      {"saturation", {e("saturation", {{"amount", 0.3}})}},
      {"vibrance", {e("vibrance", {{"amount", 0.5}})}},
      {"exposure+gamma+temperature+tint+highlights+shadows+rgb (one table)",
       {e("exposure", {{"stops", 0.3}}), e("gamma", {{"value", 1.2}}), e("temperature", {{"amount", 0.2}}), e("tint", {{"amount", 0.1}}),
        e("highlights", {{"amount", -0.3}}), e("shadows", {{"amount", 0.3}}), e("rgb", {{"red", 1.05}})}},
      {"vignette", {e("vignette")}},
      {"grayscale", {e("grayscale")}},
      {"black_white", {e("black_white")}},
      {"sepia", {e("sepia")}},
      {"filter teal_orange", {e("filter", {{"look", 0}})}},
      {"sharpen (default)", {e("sharpen")}},
      {"blur radius 0.006 (default)", {e("blur")}},
      {"blur radius 0.03", {e("blur", {{"radius", 0.03}})}},
      {"cinematic preset (exposure, contrast, vibrance, filter, vignette)",
       {e("exposure", {{"stops", 0.2}}), e("contrast", {{"amount", 0.15}}), e("vibrance", {{"amount", 0.3}}), e("filter", {{"look", 0}, {"amount", 0.7}}),
        e("vignette", {{"amount", 0.35}})}},
  };
  for (const auto& sz : sizes) {
    RgbaBuffer a, b, out, work;
    a.resize(sz.w, sz.h);
    b.resize(sz.w, sz.h);
    out.resize(sz.w, sz.h);
    work.resize(sz.w, sz.h);
    fill(a, 1);
    fill(b, 2);
    std::printf("\n%s (%dx%d), ms per frame:\n", sz.name, sz.w, sz.h);
    for (const auto& fx : effects) {
      const double ms = ms_per(frames, [&] {
        work.px = a.px;
        apply_effects(fx.list, work.view(), 0, 0, sz.w, sz.h, sz.h);
      });
      std::printf("  %-70s %7.2f\n", fx.name, ms);
    }
    const double copy = ms_per(frames, [&] { work.px = a.px; });
    std::printf("  %-70s %7.2f\n", "(picture copy, included above)", copy);
    const char* names[] = {"dissolve", "wipe", "slide", "zoom_in", "zoom_out", "blur"};
    const TransitionKind kinds[] = {TransitionKind::dissolve, TransitionKind::wipe, TransitionKind::slide,
                                    TransitionKind::zoom_in, TransitionKind::zoom_out, TransitionKind::blur};
    for (int i = 0; i < 6; ++i) {
      const double ms = ms_per(frames, [&] {
        work.px = b.px;
        apply_transition(kinds[i], Direction::left, 0.5, a.view(), work.view(), out.view());
      });
      std::printf("  transition %-59s %7.2f\n", names[i], ms);
    }
    const double fade = ms_per(frames, [&] { apply_fade(out.view(), 0.5, 0); });
    std::printf("  %-70s %7.2f\n", "fade / dip", fade);
  }
  return 0;
}
