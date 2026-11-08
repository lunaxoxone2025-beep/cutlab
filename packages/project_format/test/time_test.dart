import 'package:cutlab_project_format/cutlab_project_format.dart';
import 'package:test/test.dart';

void main() {
  group('Rational', () {
    test('normalizes sign and gcd', () {
      expect(Rational(-60, -2002), Rational(30, 1001));
      expect(Rational(4, -8), Rational(-1, 2));
    });
    test('rejects zero denominator', () {
      expect(() => Rational(1, 0), throwsArgumentError);
    });
    test('json round trip', () {
      expect(Rational.fromJson(Rational.fps29_97.toJson()), Rational.fps29_97);
    });
  });

  group('mulDiv', () {
    test('rounds toward -inf, +inf and nearest', () {
      expect(mulDiv(7, 1, 2, Rounding.down), 3);
      expect(mulDiv(7, 1, 2, Rounding.up), 4);
      expect(mulDiv(-7, 1, 2, Rounding.down), -4);
      expect(mulDiv(-7, 1, 2, Rounding.up), -3);
      expect(mulDiv(-7, 1, 2, Rounding.nearest), -4);
      expect(mulDiv(5, 1, 3, Rounding.nearest), 2);
    });
    test('uses an exact intermediate', () {
      const big = 1 << 62;
      expect(mulDiv(big, 3, 6, Rounding.down), big ~/ 2);
      expect(() => mulDiv(big, 6, 3), throwsRangeError);
    });
  });

  group('frames and ticks (must match the C++ core)', () {
    const rates = [
      Rational.fps23_976,
      Rational.fps24,
      Rational.fps25,
      Rational.fps29_97,
      Rational.fps30,
      Rational.fps50,
      Rational.fps59_94,
      Rational.fps60,
      Rational.fps120,
    ];
    for (final fps in rates) {
      test('frame boundaries are exact at $fps fps over 3 hours', () {
        const n = 3 * 3600 * 120 + 7;
        final t = framesToTicks(n, fps);
        expect(ticksToFrames(t, fps), n);
        expect(ticksToFrames(t - 1, fps), n - 1);
        expect((ticksPerSecond * fps.den) % fps.num, 0);
      });
    }
    test('known values', () {
      expect(framesToTicks(1, Rational.fps29_97), 23543520);
      expect(framesToTicks(30, Rational.fps30), ticksPerSecond);
      expect(snapToFrame(framesToTicks(10, Rational.fps30) + 1000, Rational.fps30), framesToTicks(10, Rational.fps30));
      expect(secondsToTicks(1.5), ticksPerSecond * 3 ~/ 2);
    });
  });
}
