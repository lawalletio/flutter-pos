import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/domain/config/settings_state.dart';
import 'package:lawallet_pos/domain/prize/prize_lottery.dart';

void main() {
  const a = PrizeCoupon(id: 'a', text: 'A', chancePercent: 100);
  const b = PrizeCoupon(id: 'b', text: 'B', chancePercent: 100);
  const zero = PrizeCoupon(id: 'z', text: 'Z', chancePercent: 0);

  group('rollPrize', () {
    test('disabled returns null', () {
      expect(
        rollPrize(enabled: false, coupons: [a], roll: () => 0),
        isNull,
      );
    });

    test('empty list returns null', () {
      expect(
        rollPrize(enabled: true, coupons: const [], roll: () => 0),
        isNull,
      );
    });

    test('0% never wins', () {
      expect(
        rollPrize(enabled: true, coupons: [zero], roll: () => 0),
        isNull,
      );
    });

    test('100% on first row wins that row', () {
      expect(
        rollPrize(enabled: true, coupons: [a, b], roll: () => 50),
        a,
      );
    });

    test('first-hit skips later rows', () {
      var calls = 0;
      final winner = rollPrize(
        enabled: true,
        coupons: [zero, a, b],
        roll: () {
          calls++;
          return 0;
        },
      );
      expect(winner, a);
      expect(calls, 1); // 0% is skipped without a roll; b is never reached
    });

    test('at most one winner', () {
      final winner = rollPrize(
        enabled: true,
        coupons: [a, b],
        roll: () => 0,
      );
      expect(winner, isNotNull);
      expect(winner!.id, 'a');
    });
  });
}
