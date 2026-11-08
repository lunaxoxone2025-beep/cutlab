// CUTLAB core — exact time arithmetic.
//
// All timeline positions and durations are stored as signed 64-bit integer
// "ticks". One second is 705,600,000 ticks (the "flick" unit). That number is
// divisible by every common video frame rate (23.976, 24, 25, 29.97, 30, 48,
// 50, 59.94, 60, 90, 100, 119.88, 120) and audio rate (8 k – 192 k), so frame
// and sample boundaries are exact integers and never drift.
//
// int64 ticks cover ±414 years; values stay below 2^53 for ~148 days, so they
// also round-trip safely through JSON readers that use IEEE doubles.
#pragma once

#include <cstdint>
#include <string>

namespace cutlab {

using Ticks = std::int64_t;

inline constexpr Ticks kTicksPerSecond = 705'600'000;

enum class Rounding { Down, Up, Nearest };

// A normalized rational number (den > 0, gcd(num, den) == 1).
struct Rational {
  std::int64_t num = 0;
  std::int64_t den = 1;

  // Throws std::invalid_argument when den == 0.
  static Rational make(std::int64_t num, std::int64_t den);

  bool is_positive() const { return num > 0; }
  double to_double() const { return static_cast<double>(num) / static_cast<double>(den); }
  friend bool operator==(const Rational& a, const Rational& b) { return a.num == b.num && a.den == b.den; }
  friend bool operator!=(const Rational& a, const Rational& b) { return !(a == b); }
};

// Common frame rates.
namespace rates {
inline constexpr Rational k23_976{24000, 1001};
inline constexpr Rational k24{24, 1};
inline constexpr Rational k25{25, 1};
inline constexpr Rational k29_97{30000, 1001};
inline constexpr Rational k30{30, 1};
inline constexpr Rational k50{50, 1};
inline constexpr Rational k59_94{60000, 1001};
inline constexpr Rational k60{60, 1};
inline constexpr Rational k120{120, 1};
}  // namespace rates

// Computes value * mul / div with a 128-bit intermediate and the requested
// rounding. Throws std::overflow_error if the result does not fit in int64
// and std::invalid_argument if div == 0.
std::int64_t mul_div(std::int64_t value, std::int64_t mul, std::int64_t div, Rounding r);

// Converts `value` expressed in time base `from` (seconds per unit) to time
// base `to`, like FFmpeg's av_rescale_q_rnd.
std::int64_t rescale(std::int64_t value, Rational from, Rational to, Rounding r = Rounding::Nearest);

// Start time of frame `frame` at frame rate `fps` (frames per second).
Ticks frames_to_ticks(std::int64_t frame, Rational fps);

// Index of the frame displayed at time `t` (floor by default).
std::int64_t ticks_to_frames(Ticks t, Rational fps, Rounding r = Rounding::Down);

// Snaps `t` to the nearest frame boundary at `fps`.
Ticks snap_to_frame(Ticks t, Rational fps);

// Seconds <-> ticks for UI input only. Never use doubles for stored edits.
Ticks seconds_to_ticks(double seconds);
double ticks_to_seconds(Ticks t);

// Non-drop-frame timecode "HH:MM:SS:FF" (negative times get a '-' prefix).
// The frame field uses the nominal (rounded) rate, e.g. 30 for 29.97.
std::string format_timecode(Ticks t, Rational fps);

}  // namespace cutlab
