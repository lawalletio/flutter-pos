import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/domain/config/settings_state.dart';
import 'package:lawallet_pos/domain/prize/prize_wheel.dart';

void main() {
  const cafe = PrizeCoupon(id: 'cafe', text: 'Café', chancePercent: 10);
  const postre = PrizeCoupon(id: 'postre', text: 'Postre', chancePercent: 20);
  const zero = PrizeCoupon(id: 'nada', text: 'Nada', chancePercent: 0);

  List<WheelSlice> slicesOf(List<PrizeCoupon> coupons) =>
      buildWheelSlices(coupons, keepPlayingLabel: 'Seguí participando');

  test('remainder becomes the keep-playing wedge', () {
    final slices = slicesOf([cafe, postre, zero]);
    expect(slices.map((s) => s.id), ['keep-playing', 'cafe', 'postre']);
    expect(slices.map((s) => s.weight), [70, 10, 20]);
    expect(sliceStart(slices, 0), 0);
    expect(sliceStart(slices, 1), closeTo(0.70, 0.0001));
    expect(sliceStart(slices, 2), closeTo(0.80, 0.0001));
  });

  test('chances at or above 100% leave no miss wedge', () {
    const a = PrizeCoupon(id: 'a', text: 'A', chancePercent: 80);
    const b = PrizeCoupon(id: 'b', text: 'B', chancePercent: 80);
    final slices = slicesOf([a, b]);
    expect(slices.map((s) => s.id), ['a', 'b']);
    expect(sliceStart(slices, 1), 0.5);
  });

  test('a chance of zero is not a prize', () {
    expect(wheelHasPrizes(const [zero]), isFalse);
    expect(wheelHasPrizes(const [cafe]), isTrue);
  });

  test('no prizes is a single keep-playing wedge', () {
    final slices = slicesOf([zero]);
    expect(slices, hasLength(1));
    expect(slices.single.isPrize, isFalse);
    expect(sliceIndexAt(slices, 0.4), 0);
  });

  test('the pointer fraction round-trips through the landing turns', () {
    final slices = slicesOf([cafe, postre]);
    final fraction = landingFraction(slices, 2, 0.5);
    final turns = landingTurns(fraction, spins: 6);
    final selected = (-turns) % 1;
    expect(sliceIndexAt(slices, selected), 2);
    expect(selected, closeTo(fraction, 0.0001));
  });

  test('pick follows the weights', () {
    final slices = slicesOf([cafe, postre]);
    expect(pickSliceIndex(slices, 0.0), 0);
    expect(pickSliceIndex(slices, 0.69), 0);
    expect(pickSliceIndex(slices, 0.70), 1);
    expect(pickSliceIndex(slices, 0.95), 2);
  });

  test('pieces keep each prize area and stay under one twelfth', () {
    final distributed = distributeWheelSlices(slicesOf([cafe, postre]));
    expect(distributed.length, greaterThan(3));
    final area = <String, int>{};
    for (final slice in distributed) {
      area[slice.id] = (area[slice.id] ?? 0) + slice.weight;
    }
    expect(area, {'keep-playing': 70, 'cafe': 10, 'postre': 20});
    final total = wheelWeight(distributed);
    final cap = math.max(1, total ~/ 12);
    expect(distributed.every((slice) => slice.weight <= cap), isTrue);
    expect(
      distributed.where((slice) => slice.id == 'cafe').length,
      greaterThan(1),
    );
    expect(
      distributed.where((slice) => slice.id == 'postre').length,
      greaterThan(1),
    );
  });

  test('the same prize is not one contiguous block', () {
    final distributed = distributeWheelSlices(slicesOf([cafe, postre]));
    final cafeAt = [
      for (var i = 0; i < distributed.length; i++)
        if (distributed[i].id == 'cafe') i,
    ];
    expect((cafeAt[1] - cafeAt[0]) % distributed.length, isNot(1));
    expect(distributed.first.id, isNot(distributed.last.id));
  });

  test('the wheel button follows the tip setting', () {
    const prizes = true;
    expect(
      offerWheelSpin(
        prizesEnabled: true,
        hasPrizes: prizes,
        offer: WheelOffer.tipOnly,
        tipSats: 100,
      ),
      isTrue,
    );
    expect(
      offerWheelSpin(
        prizesEnabled: true,
        hasPrizes: prizes,
        offer: WheelOffer.tipOnly,
        tipSats: 0,
      ),
      isFalse,
    );
    expect(
      offerWheelSpin(
        prizesEnabled: true,
        hasPrizes: prizes,
        offer: WheelOffer.always,
        tipSats: 0,
      ),
      isTrue,
    );
    expect(
      offerWheelSpin(
        prizesEnabled: false,
        hasPrizes: prizes,
        offer: WheelOffer.always,
        tipSats: 500,
      ),
      isFalse,
    );
    expect(
      offerWheelSpin(
        prizesEnabled: true,
        hasPrizes: false,
        offer: WheelOffer.always,
        tipSats: 500,
      ),
      isFalse,
    );
  });

  test('speed scales the laps and the default acceleration is unchanged', () {
    expect(
      wheelExtraSpins(kWheelDurationDefaultMs, speed: 2),
      closeTo(wheelExtraSpins(kWheelDurationDefaultMs) * 2, 0.001),
    );
    expect(
      wheelSpinProgress(0.28, acceleration: 1),
      closeTo(wheelSpinProgress(0.28), 0.0001),
    );
    expect(
      wheelSpinProgress(0.2, acceleration: 2),
      greaterThan(wheelSpinProgress(0.2)),
    );
  });

  test('the slow part of the spin lasts long enough to read', () {
    expect(wheelSpinProgress(0), 0);
    expect(wheelSpinProgress(1), closeTo(1, 1e-9));
    final opening = wheelSpinProgress(0.28);
    expect(opening, greaterThan(0.55));
    expect(opening, lessThan(0.70));
    // The second half still sweeps a readable arc instead of creeping.
    final tail = 1 - wheelSpinProgress(0.5);
    expect(tail, greaterThan(0.18));
    expect(tail, lessThan(0.30));
    expect(wheelSpinProgress(0.86), greaterThan(0.95));
    var previous = 0.0;
    for (var i = 1; i <= 20; i++) {
      final progress = wheelSpinProgress(i / 20);
      expect(progress, greaterThan(previous));
      previous = progress;
    }
    final burst = wheelSpinProgress(0.1);
    final coast = wheelSpinProgress(0.6) - wheelSpinProgress(0.5);
    expect(coast, lessThan(burst / 2));
  });

  test('a long wheel duration slows the spin instead of adding laps', () {
    final normal = wheelExtraSpins(kWheelDurationDefaultMs) /
        (kWheelDurationDefaultMs / 1000);
    final atCap = wheelExtraSpins(kWheelSlowAfterMs) / (kWheelSlowAfterMs / 1000);
    expect(atCap, closeTo(normal, 0.001));
    expect(wheelExtraSpins(kWheelDurationMaxMs), wheelExtraSpins(kWheelSlowAfterMs));
    final slow = wheelExtraSpins(kWheelDurationMaxMs) /
        (kWheelDurationMaxMs / 1000);
    expect(slow, lessThan(normal));
  });

  test('a single full-circle prize is still cut into pieces', () {
    const only = PrizeCoupon(id: 'solo', text: 'Solo', chancePercent: 100);
    final distributed = distributeWheelSlices(slicesOf([only]));
    expect(distributed.length, greaterThan(1));
    expect(
      distributed.fold<int>(0, (sum, slice) => sum + slice.weight),
      100,
    );
    expect(distributed.every((slice) => slice.id == 'solo'), isTrue);
  });
}
