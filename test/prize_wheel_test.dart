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

  test('every throw stops on its target, either way', () {
    const turn = 2 * math.pi;
    for (final velocity in [6.0, -6.0, 14.0, -22.0, 40.0]) {
      for (final target in [0.0, 0.13, 0.5, 0.97]) {
        for (final ms in [kWheelDurationMinMs, 6000, kWheelDurationMaxMs]) {
          final plan = planWheelThrow(
            angle: 1.7,
            velocity: velocity,
            target: target,
            durationMs: ms,
          );
          final end = wheelFractionAt(plan.angleAt(plan.seconds));
          final off = (end - target).abs();
          expect(math.min(off, 1 - off), lessThan(1e-9));
          expect(plan.speedAt(0), velocity.abs());
          expect(plan.speedAt(plan.seconds), 0);
          expect(plan.distance, greaterThan(turn / 2));
          var last = plan.angleAt(0);
          for (var i = 1; i <= 50; i++) {
            final at = plan.angleAt(plan.seconds * i / 50);
            expect((at - last) * velocity.sign, greaterThanOrEqualTo(0));
            last = at;
          }
        }
      }
    }
  });

  test('a harder throw spins further and a slow one does not count', () {
    const turn = 2 * math.pi;
    expect(wheelFlingCounts(kWheelMinFlingTurns * turn * 0.9), isFalse);
    expect(wheelFlingCounts(-kWheelMinFlingTurns * turn), isTrue);
    WheelThrow plan(double velocity) => planWheelThrow(
          angle: 0,
          velocity: velocity,
          target: 0.4,
          durationMs: kWheelDurationDefaultMs,
        );
    final soft = plan(kWheelMinFlingTurns * turn);
    final hard = plan(kWheelMaxFlingTurns * turn);
    expect(hard.distance, greaterThan(soft.distance + 2 * turn));
    expect(hard.seconds, greaterThan(soft.seconds));
  });

  test('the duration setting stretches the spin', () {
    double seconds(int ms) => planWheelThrow(
          angle: 0,
          velocity: 15,
          target: 0.25,
          durationMs: ms,
        ).seconds;
    expect(seconds(kWheelDurationMaxMs), greaterThan(seconds(6000) * 1.8));
    expect(seconds(kWheelDurationMinMs), lessThan(seconds(6000) * 0.6));
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
