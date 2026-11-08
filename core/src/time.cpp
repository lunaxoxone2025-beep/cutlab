#include "cutlab/time.hpp"

#include <cmath>
#include <cstdio>
#include <limits>
#include <numeric>
#include <stdexcept>

namespace cutlab {
namespace {

// Portable unsigned 64x64 -> 128 multiply (no __int128, so MSVC works too).
void mul_u64(std::uint64_t a, std::uint64_t b, std::uint64_t& hi, std::uint64_t& lo) {
  const std::uint64_t a_lo = a & 0xffffffffu, a_hi = a >> 32;
  const std::uint64_t b_lo = b & 0xffffffffu, b_hi = b >> 32;
  const std::uint64_t p0 = a_lo * b_lo;
  const std::uint64_t p1 = a_lo * b_hi;
  const std::uint64_t p2 = a_hi * b_lo;
  const std::uint64_t p3 = a_hi * b_hi;
  const std::uint64_t mid = (p0 >> 32) + (p1 & 0xffffffffu) + (p2 & 0xffffffffu);
  lo = (mid << 32) | (p0 & 0xffffffffu);
  hi = p3 + (p1 >> 32) + (p2 >> 32) + (mid >> 32);
}

// Unsigned 128 / 64 -> quotient (must fit in 64 bits) and remainder.
void div_u128(std::uint64_t hi, std::uint64_t lo, std::uint64_t d, std::uint64_t& q, std::uint64_t& rem) {
  if (hi >= d) throw std::overflow_error("cutlab::mul_div: result overflows int64");
  std::uint64_t r = hi;
  q = 0;
  for (int i = 63; i >= 0; --i) {
    const bool carry = (r >> 63) != 0;
    r = (r << 1) | ((lo >> i) & 1u);
    if (carry || r >= d) {
      r -= d;
      q |= (std::uint64_t{1} << i);
    }
  }
  rem = r;
}

std::uint64_t uabs(std::int64_t v) {
  return v < 0 ? std::uint64_t{0} - static_cast<std::uint64_t>(v) : static_cast<std::uint64_t>(v);
}

}  // namespace

Rational Rational::make(std::int64_t num, std::int64_t den) {
  if (den == 0) throw std::invalid_argument("cutlab::Rational: zero denominator");
  if (den < 0) {
    num = -num;
    den = -den;
  }
  const std::int64_t g = std::gcd(num, den);
  if (g > 1) {
    num /= g;
    den /= g;
  }
  return Rational{num, den};
}

std::int64_t mul_div(std::int64_t value, std::int64_t mul, std::int64_t div, Rounding r) {
  if (div == 0) throw std::invalid_argument("cutlab::mul_div: division by zero");
  const bool negative = ((value < 0) != (mul < 0)) != (div < 0);
  std::uint64_t hi = 0, lo = 0, q = 0, rem = 0;
  const std::uint64_t d = uabs(div);
  mul_u64(uabs(value), uabs(mul), hi, lo);
  div_u128(hi, lo, d, q, rem);

  // Round the magnitude, remembering that "down" means toward -infinity.
  if (rem != 0) {
    bool bump = false;
    switch (r) {
      case Rounding::Down: bump = negative; break;
      case Rounding::Up: bump = !negative; break;
      case Rounding::Nearest: bump = rem >= d - rem; break;  // half away from zero
    }
    if (bump) {
      if (q == std::numeric_limits<std::uint64_t>::max()) throw std::overflow_error("cutlab::mul_div: overflow");
      ++q;
    }
  }
  const std::uint64_t limit = negative ? std::uint64_t{1} << 63 : (std::uint64_t{1} << 63) - 1;
  if (q > limit) throw std::overflow_error("cutlab::mul_div: result overflows int64");
  if (negative) return q == (std::uint64_t{1} << 63) ? std::numeric_limits<std::int64_t>::min() : -static_cast<std::int64_t>(q);
  return static_cast<std::int64_t>(q);
}

std::int64_t rescale(std::int64_t value, Rational from, Rational to, Rounding r) {
  from = Rational::make(from.num, from.den);
  to = Rational::make(to.num, to.den);
  if (to.num == 0) throw std::invalid_argument("cutlab::rescale: zero target time base");
  // value * (from.num / from.den) / (to.num / to.den)
  //   = value * from.num * to.den / (from.den * to.num)
  // Reduce cross terms first to keep the intermediates small.
  std::int64_t a = from.num, b = to.den, c = from.den, d = to.num;
  std::int64_t g = std::gcd(a, d);
  if (g > 1) { a /= g; d /= g; }
  g = std::gcd(b, c);
  if (g > 1) { b /= g; c /= g; }
  const std::int64_t mul = mul_div(a, b, 1, Rounding::Down);
  const std::int64_t div = mul_div(c, d, 1, Rounding::Down);
  return mul_div(value, mul, div, r);
}

Ticks frames_to_ticks(std::int64_t frame, Rational fps) {
  if (!Rational::make(fps.num, fps.den).is_positive()) throw std::invalid_argument("cutlab: frame rate must be positive");
  // frame duration in seconds = fps.den / fps.num
  return rescale(frame, Rational::make(fps.den, fps.num), Rational{1, kTicksPerSecond}, Rounding::Nearest);
}

std::int64_t ticks_to_frames(Ticks t, Rational fps, Rounding r) {
  if (!Rational::make(fps.num, fps.den).is_positive()) throw std::invalid_argument("cutlab: frame rate must be positive");
  return rescale(t, Rational{1, kTicksPerSecond}, Rational::make(fps.den, fps.num), r);
}

Ticks snap_to_frame(Ticks t, Rational fps) {
  return frames_to_ticks(ticks_to_frames(t, fps, Rounding::Nearest), fps);
}

Ticks seconds_to_ticks(double seconds) {
  const double v = std::round(seconds * static_cast<double>(kTicksPerSecond));
  if (!(std::fabs(v) < 9.2e18)) throw std::overflow_error("cutlab::seconds_to_ticks: out of range");
  return static_cast<Ticks>(v);
}

double ticks_to_seconds(Ticks t) { return static_cast<double>(t) / static_cast<double>(kTicksPerSecond); }

std::string format_timecode(Ticks t, Rational fps) {
  fps = Rational::make(fps.num, fps.den);
  if (!fps.is_positive()) throw std::invalid_argument("cutlab: frame rate must be positive");
  const bool negative = t < 0;
  const std::int64_t frames = ticks_to_frames(negative ? -t : t, fps, Rounding::Down);
  const std::int64_t nominal = std::max<std::int64_t>(1, mul_div(fps.num, 1, fps.den, Rounding::Nearest));
  const std::int64_t ff = frames % nominal;
  const std::int64_t total_s = frames / nominal;
  char buf[48];
  std::snprintf(buf, sizeof buf, "%s%02lld:%02lld:%02lld:%02lld", negative ? "-" : "",
                static_cast<long long>(total_s / 3600), static_cast<long long>((total_s / 60) % 60),
                static_cast<long long>(total_s % 60), static_cast<long long>(ff));
  return buf;
}

}  // namespace cutlab
