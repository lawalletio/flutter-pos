import '../config/settings_state.dart';

/// Roll `0..100` inclusive; first coupon where `roll < chancePercent` wins.
typedef PrizeRollFn = int Function();

/// At most one winner: walk [coupons] in order (first-hit).
PrizeCoupon? rollPrize({
  required bool enabled,
  required List<PrizeCoupon> coupons,
  required PrizeRollFn roll,
}) {
  if (!enabled || coupons.isEmpty) return null;
  for (final c in coupons) {
    final chance = c.chancePercent;
    if (chance <= 0) continue;
    if (roll() < chance) return c;
  }
  return null;
}
