/// Exact time arithmetic shared with the C++ core (see core/include/cutlab/time.hpp).
///
/// Every stored time is an integer number of ticks; one second is
/// [ticksPerSecond] ticks. Frame boundaries of all common frame rates
/// (23.976 … 120 fps) are exact integers in this unit.
library;

/// Ticks per second (the "flick" unit, 705,600,000).
const int ticksPerSecond = 705600000;

/// A normalized rational number (denominator > 0, reduced).
class Rational {
  final int num;
  final int den;

  const Rational._(this.num, this.den);

  factory Rational(int num, int den) {
    if (den == 0) {
      throw ArgumentError.value(den, 'den', 'must not be zero');
    }
    if (den < 0) {
      num = -num;
      den = -den;
    }
    final g = num.gcd(den);
    return g > 1 ? Rational._(num ~/ g, den ~/ g) : Rational._(num, den);
  }

  static const fps23_976 = Rational._(24000, 1001);
  static const fps24 = Rational._(24, 1);
  static const fps25 = Rational._(25, 1);
  static const fps29_97 = Rational._(30000, 1001);
  static const fps30 = Rational._(30, 1);
  static const fps50 = Rational._(50, 1);
  static const fps59_94 = Rational._(60000, 1001);
  static const fps60 = Rational._(60, 1);
  static const fps120 = Rational._(120, 1);
  static const one = Rational._(1, 1);

  bool get isPositive => num > 0;
  double toDouble() => num / den;

  Map<String, Object?> toJson() => {'num': num, 'den': den};

  factory Rational.fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('rational must be an object {num, den}');
    }
    final n = json['num'];
    final d = json['den'];
    if (n is! int || d is! int || d == 0) {
      throw const FormatException('rational needs integer num and non-zero den');
    }
    return Rational(n, d);
  }

  @override
  bool operator ==(Object other) => other is Rational && other.num == num && other.den == den;

  @override
  int get hashCode => Object.hash(num, den);

  @override
  String toString() => den == 1 ? '$num' : '$num/$den';
}

/// Rounding mode for [mulDiv]. [down] rounds toward negative infinity,
/// [nearest] rounds half away from zero.
enum Rounding { down, up, nearest }

/// value * mul / div, computed exactly with [BigInt] and rounded.
int mulDiv(int value, int mul, int div, [Rounding rounding = Rounding.nearest]) {
  if (div == 0) {
    throw ArgumentError.value(div, 'div', 'must not be zero');
  }
  var n = BigInt.from(value) * BigInt.from(mul);
  var d = BigInt.from(div);
  if (d.isNegative) {
    n = -n;
    d = -d;
  }
  var q = n ~/ d; // truncates toward zero
  final r = n - q * d; // same sign as n
  if (r != BigInt.zero) {
    switch (rounding) {
      case Rounding.down:
        if (n.isNegative) q -= BigInt.one;
      case Rounding.up:
        if (!n.isNegative) q += BigInt.one;
      case Rounding.nearest:
        if (r.abs() * BigInt.two >= d) q += n.isNegative ? -BigInt.one : BigInt.one;
    }
  }
  if (!q.isValidInt) {
    throw RangeError('mulDiv result does not fit in a 64-bit int');
  }
  return q.toInt();
}

/// Start time (ticks) of frame [frame] at frame rate [fps].
int framesToTicks(int frame, Rational fps) {
  if (!fps.isPositive) throw ArgumentError.value(fps, 'fps', 'must be positive');
  return mulDiv(frame, ticksPerSecond * fps.den, fps.num);
}

/// Index of the frame shown at [ticks] (floor by default).
int ticksToFrames(int ticks, Rational fps, [Rounding rounding = Rounding.down]) {
  if (!fps.isPositive) throw ArgumentError.value(fps, 'fps', 'must be positive');
  return mulDiv(ticks, fps.num, ticksPerSecond * fps.den, rounding);
}

/// Snaps [ticks] to the nearest frame boundary.
int snapToFrame(int ticks, Rational fps) => framesToTicks(ticksToFrames(ticks, fps, Rounding.nearest), fps);

/// Seconds → ticks, for user input only. Stored values are always ticks.
int secondsToTicks(double seconds) => (seconds * ticksPerSecond).round();

double ticksToSeconds(int ticks) => ticks / ticksPerSecond;
