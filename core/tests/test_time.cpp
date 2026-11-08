// Unit tests for cutlab core time arithmetic. Dependency-free on purpose so
// the core builds on every CI runner without downloading a test framework.
#include <cstdint>
#include <cstdio>
#include <limits>
#include <stdexcept>
#include <string>

#include "cutlab/cutlab_core.h"
#include "cutlab/time.hpp"

using namespace cutlab;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                     \
  do {                                                                  \
    ++g_checks;                                                         \
    if (!(cond)) {                                                      \
      ++g_failures;                                                     \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
    }                                                                   \
  } while (0)

#define CHECK_EQ(a, b)                                                                                    \
  do {                                                                                                    \
    ++g_checks;                                                                                           \
    const auto va = (a);                                                                                  \
    const auto vb = (b);                                                                                  \
    if (!(va == vb)) {                                                                                    \
      ++g_failures;                                                                                       \
      std::fprintf(stderr, "%s:%d: CHECK_EQ failed: %s == %s (%lld vs %lld)\n", __FILE__, __LINE__, #a, #b, \
                   static_cast<long long>(va), static_cast<long long>(vb));                               \
    }                                                                                                     \
  } while (0)

template <typename E, typename F>
static bool throws(F&& f) {
  try {
    f();
  } catch (const E&) {
    return true;
  } catch (...) {
    return false;
  }
  return false;
}

static void test_rational() {
  const Rational r = Rational::make(-60, -1001 * 2);
  CHECK_EQ(r.num, 30);
  CHECK_EQ(r.den, 1001);
  CHECK(Rational::make(4, -8) == (Rational{-1, 2}));
  CHECK(throws<std::invalid_argument>([] { Rational::make(1, 0); }));
}

static void test_mul_div_rounding() {
  CHECK_EQ(mul_div(7, 1, 2, Rounding::Down), 3);
  CHECK_EQ(mul_div(7, 1, 2, Rounding::Up), 4);
  CHECK_EQ(mul_div(7, 1, 2, Rounding::Nearest), 4);
  CHECK_EQ(mul_div(-7, 1, 2, Rounding::Down), -4);
  CHECK_EQ(mul_div(-7, 1, 2, Rounding::Up), -3);
  CHECK_EQ(mul_div(-7, 1, 2, Rounding::Nearest), -4);
  CHECK_EQ(mul_div(5, 1, 3, Rounding::Nearest), 2);
  // 128-bit intermediate: (2^62 * 6) / 3 = 2^63 overflows; (2^62 * 3) / 6 does not.
  const std::int64_t big = std::int64_t{1} << 62;
  CHECK_EQ(mul_div(big, 3, 6, Rounding::Down), big / 2);
  CHECK(throws<std::overflow_error>([&] { mul_div(big, 6, 3, Rounding::Down); }));
  CHECK_EQ(mul_div(std::numeric_limits<std::int64_t>::min(), 1, 1, Rounding::Down), std::numeric_limits<std::int64_t>::min());
  CHECK(throws<std::invalid_argument>([] { mul_div(1, 1, 0, Rounding::Down); }));
}

static void test_frame_rates_are_exact() {
  const Rational all[] = {rates::k23_976, rates::k24, rates::k25, rates::k29_97, rates::k30,
                          rates::k50,     rates::k59_94, rates::k60, rates::k120};
  for (const Rational& fps : all) {
    // One frame is an exact integer number of ticks...
    CHECK_EQ(mul_div(kTicksPerSecond, fps.den, fps.num, Rounding::Down) * fps.num, kTicksPerSecond * fps.den);
    // ...so a long run of frames never drifts: frame N of a 3-hour timeline round-trips.
    const std::int64_t n = 3 * 3600 * 120 + 7;
    CHECK_EQ(ticks_to_frames(frames_to_ticks(n, fps), fps), n);
    // A tick before frame N belongs to frame N-1.
    CHECK_EQ(ticks_to_frames(frames_to_ticks(n, fps) - 1, fps), n - 1);
  }
  CHECK_EQ(frames_to_ticks(1, rates::k29_97), 23'543'520);
  CHECK_EQ(frames_to_ticks(30000, rates::k29_97), 1001LL * kTicksPerSecond);
  // Audio sample rates divide evenly too.
  CHECK_EQ(kTicksPerSecond % 48000, 0);
  CHECK_EQ(kTicksPerSecond % 44100, 0);
}

static void test_rescale_and_snap() {
  // 90 kHz MPEG-TS timestamps -> ticks.
  CHECK_EQ(rescale(90000, Rational{1, 90000}, Rational{1, kTicksPerSecond}), kTicksPerSecond);
  // Variable-frame-rate source in a 1/1000 time base.
  CHECK_EQ(rescale(1234, Rational{1, 1000}, Rational{1, kTicksPerSecond}), 1234LL * 705600);
  const Ticks t = frames_to_ticks(10, rates::k30) + 1000;
  CHECK_EQ(snap_to_frame(t, rates::k30), frames_to_ticks(10, rates::k30));
  CHECK_EQ(seconds_to_ticks(1.5), kTicksPerSecond * 3 / 2);
  CHECK(throws<std::invalid_argument>([] { frames_to_ticks(1, Rational{0, 1}); }));
}

static void test_timecode() {
  CHECK(format_timecode(0, rates::k30) == "00:00:00:00");
  CHECK(format_timecode(frames_to_ticks(30 * 3661 + 12, rates::k30), rates::k30) == "01:01:01:12");
  CHECK(format_timecode(-frames_to_ticks(5, rates::k25), rates::k25) == "-00:00:00:05");
  CHECK(format_timecode(frames_to_ticks(29, rates::k29_97), rates::k29_97) == "00:00:00:29");
}

static void test_c_api() {
  int64_t out = 0;
  CHECK(std::string(cutlab_core_version()).size() > 0);
  CHECK_EQ(cutlab_ticks_per_second(), kTicksPerSecond);
  CHECK_EQ(cutlab_frames_to_ticks(30, 30, 1, &out), CUTLAB_OK);
  CHECK_EQ(out, kTicksPerSecond);
  CHECK_EQ(cutlab_ticks_to_frames(kTicksPerSecond - 1, 30, 1, CUTLAB_ROUND_DOWN, &out), CUTLAB_OK);
  CHECK_EQ(out, 29);
  CHECK_EQ(cutlab_frames_to_ticks(1, 30, 0, &out), CUTLAB_ERR_INVALID_ARGUMENT);
  CHECK_EQ(cutlab_frames_to_ticks(1, 30, 1, nullptr), CUTLAB_ERR_INVALID_ARGUMENT);
  CHECK_EQ(cutlab_rescale(std::numeric_limits<int64_t>::max(), 2, 1, 1, 1, CUTLAB_ROUND_DOWN, &out), CUTLAB_ERR_OVERFLOW);
}

int main() {
  test_rational();
  test_mul_div_rounding();
  test_frame_rates_are_exact();
  test_rescale_and_snap();
  test_timecode();
  test_c_api();
  std::printf("%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
