import 'dart:math' as math;

import '../config/settings_state.dart';

/// Slice that fills the wheel when no prize is drawn.
const kKeepPlayingId = 'keep-playing';

/// One wedge. [weight] is the relative size; the circle is their sum.
class WheelSlice {
  const WheelSlice({
    required this.id,
    required this.label,
    required this.weight,
    this.prize,
  });

  final String id;
  final String label;
  final int weight;
  final PrizeCoupon? prize;

  bool get isPrize => prize != null;
}

/// A wedge only exists for a coupon with a chance above zero.
bool wheelHasPrizes(List<PrizeCoupon> coupons) =>
    coupons.any((coupon) => coupon.chancePercent > 0);

/// Prize wedges use [PrizeCoupon.chancePercent]. Whatever is left of 100% is
/// "keep playing". Chances that already add up to 100% or more leave no miss
/// wedge and are scaled to the circle.
List<WheelSlice> buildWheelSlices(
  List<PrizeCoupon> coupons, {
  required String keepPlayingLabel,
}) {
  final prizes = <WheelSlice>[
    for (final coupon in coupons)
      if (coupon.chancePercent > 0)
        WheelSlice(
          id: coupon.id,
          label: coupon.text,
          weight: coupon.chancePercent,
          prize: coupon,
        ),
  ];
  final sum = prizes.fold<int>(0, (total, slice) => total + slice.weight);
  final miss = sum >= 100 ? 0 : 100 - sum;
  if (prizes.isEmpty) {
    return [
      WheelSlice(id: kKeepPlayingId, label: keepPlayingLabel, weight: 1),
    ];
  }
  if (miss == 0) return prizes;
  return [
    WheelSlice(id: kKeepPlayingId, label: keepPlayingLabel, weight: miss),
    ...prizes,
  ];
}

int wheelWeight(List<WheelSlice> slices) =>
    slices.fold<int>(0, (total, slice) => total + slice.weight);

/// Cuts every wedge into smaller pieces and spreads those pieces around the
/// circle. The total weight of each id stays the same, so the area (and the
/// odds) do not change.
List<WheelSlice> distributeWheelSlices(List<WheelSlice> slices) {
  if (slices.isEmpty) return slices;
  final total = wheelWeight(slices);
  if (total <= 1) return slices;
  final maxPiece = math.max(1, total ~/ 12);
  final minPiece = math.max(1, total ~/ 24);
  final groups = <List<int>>[
    for (final slice in slices)
      _evenWeights(slice.weight, _pieceCount(slice.weight, maxPiece, minPiece)),
  ];
  final counts = {for (var i = 0; i < groups.length; i++) i: groups[i].length};
  final order = _spreadKeys(counts);
  final cursor = List<int>.filled(groups.length, 0);
  final placed = <WheelSlice>[
    for (final key in order)
      WheelSlice(
        id: slices[key].id,
        label: slices[key].label,
        weight: groups[key][cursor[key]++],
        prize: slices[key].prize,
      ),
  ];
  return _rotateSeam(placed);
}

int _pieceCount(int weight, int maxPiece, int minPiece) {
  if (weight <= 1) return 1;
  var count = (weight + maxPiece - 1) ~/ maxPiece;
  if (count < 2 && weight >= 2 * minPiece) count = 2;
  if (count > weight) return weight;
  return count;
}

List<int> _evenWeights(int weight, int count) {
  final base = weight ~/ count;
  final extra = weight % count;
  return [for (var i = 0; i < count; i++) base + (i < extra ? 1 : 0)];
}

/// Bresenham spread: each key appears [counts] times, spaced as evenly as the
/// counts allow.
List<int> _spreadKeys(Map<int, int> counts) {
  final keys = counts.keys.toList();
  final total = counts.values.fold<int>(0, (sum, count) => sum + count);
  final acc = {for (final key in keys) key: 0};
  final out = <int>[];
  for (var step = 0; step < total; step++) {
    for (final key in keys) {
      acc[key] = acc[key]! + counts[key]!;
    }
    var best = keys.first;
    var bestScore = acc[best]!;
    for (final key in keys.skip(1)) {
      final score = acc[key]!;
      if (score > bestScore) {
        best = key;
        bestScore = score;
      }
    }
    acc[best] = acc[best]! - total;
    out.add(best);
  }
  return out;
}

/// Turns the list so the join between the first and last piece is a real
/// boundary when two different prizes meet there.
List<WheelSlice> _rotateSeam(List<WheelSlice> slices) {
  if (slices.length < 2) return slices;
  if (slices.first.id != slices.last.id) return slices;
  for (var i = 0; i < slices.length; i++) {
    final previous = slices[(i - 1 + slices.length) % slices.length];
    if (slices[i].id != previous.id) {
      return [...slices.sublist(i), ...slices.sublist(0, i)];
    }
  }
  return slices;
}

/// Where [index] starts, as a fraction of the circle. 0 is the top, clockwise.
double sliceStart(List<WheelSlice> slices, int index) {
  final total = wheelWeight(slices);
  var covered = 0;
  for (var i = 0; i < index; i++) {
    covered += slices[i].weight;
  }
  return covered / total;
}

/// Wedge under a clockwise fraction in `[0, 1)`.
int sliceIndexAt(List<WheelSlice> slices, double fraction) {
  final total = wheelWeight(slices);
  final wrapped = fraction - fraction.floorToDouble();
  var covered = 0.0;
  for (var i = 0; i < slices.length; i++) {
    covered += slices[i].weight / total;
    if (wrapped < covered || i == slices.length - 1) return i;
  }
  return 0;
}

/// A point inside the wedge, away from both edges so the pointer doesn't sit
/// on a boundary.
double landingFraction(List<WheelSlice> slices, int index, double along) {
  final total = wheelWeight(slices);
  final start = sliceStart(slices, index);
  final sweep = slices[index].weight / total;
  final t = along.clamp(0.12, 0.88);
  final value = start + sweep * t;
  // 1.0 wraps to the first wedge. Stay just inside the chosen one.
  return value >= 1 ? 0.999999 : value;
}

/// Past this length the wheel stops adding laps. Extra time only slows it down.
const kWheelSlowAfterMs = 10000;

/// The success screen offers one spin when prizes are on and the merchant's
/// [offer] matches this payment. [tipSats] is what the customer added.
bool offerWheelSpin({
  required bool prizesEnabled,
  required bool hasPrizes,
  required WheelOffer offer,
  required int tipSats,
}) {
  if (!prizesEnabled || !hasPrizes) return false;
  if (offer == WheelOffer.always) return true;
  return tipSats > 0;
}

/// The whole spin is 60% slower than the first tuning. Fewer laps in the same
/// time, so speed and acceleration drop together. The sliders still scale this.
const kWheelGlobalPace = 0.4;

/// Extra revolutions for a spin of [durationMs]. The count stays low so the
/// coast at the end is slow enough to read. Up to [kWheelSlowAfterMs] laps
/// grow with the time; past that the lap count stays put and the extra time
/// only slows the wheel further.
double wheelExtraSpins(int durationMs, {double speed = 1}) {
  final ms = clampWheelDurationMs(durationMs);
  final paced = ms < kWheelSlowAfterMs ? ms : kWheelSlowAfterMs;
  final pace = speed.isNaN ? 1.0 : speed.clamp(0.5, 2.0);
  return 3.5 * paced / kWheelDurationDefaultMs * pace * kWheelGlobalPace;
}

/// How far around the wheel a spin has traveled at normalized time [t] (0..1).
///
/// The opening dumps speed gradually, like a heavy wheel. Most of the
/// remaining time is a long coast that still sweeps about a turn, so each
/// prize stays readable, and the last moment eases to a stop.
double wheelSpinProgress(double t, {double acceleration = 1}) {
  final clamped = t.clamp(0.0, 1.0);
  final accel = acceleration.isNaN ? 1.0 : acceleration.clamp(0.5, 2.0);
  final t1 = (0.28 / accel).clamp(0.12, 0.5);
  const t2 = 0.86;
  final v0 = 5.0 * accel * kWheelGlobalPace;
  const v1 = 1.35 * kWheelGlobalPace;
  const v2 = 0.50 * kWheelGlobalPace;
  final area1 = (v0 + v1) / 2 * t1;
  final area2 = (v1 + v2) / 2 * (t2 - t1);
  final area3 = v2 / 2 * (1 - t2);
  final total = area1 + area2 + area3;
  final area = clamped <= t1
      ? _spinArea(0, clamped, v0, v1, t1)
      : clamped <= t2
          ? area1 + _spinArea(t1, clamped, v1, v2, t2)
          : area1 + area2 + _spinArea(t2, clamped, v2, 0, 1);
  return area / total;
}

double _spinArea(double t0, double t, double vStart, double vEnd, double t1) {
  final u = (t - t0) / (t1 - t0);
  final v = vStart + (vEnd - vStart) * u;
  return (vStart + v) / 2 * (t - t0);
}

/// Clockwise turns that leave [fraction] under a pointer fixed at the top.
double landingTurns(double fraction, {double spins = 6}) {
  final frac = (1 - (fraction % 1)) % 1;
  return spins + frac;
}

/// Index chosen with probability proportional to [WheelSlice.weight].
/// [unit] is in `[0, 1)`.
int pickSliceIndex(List<WheelSlice> slices, double unit) {
  final total = wheelWeight(slices);
  final mark = unit.clamp(0.0, 0.999999) * total;
  var covered = 0.0;
  for (var i = 0; i < slices.length; i++) {
    covered += slices[i].weight;
    if (mark < covered) return i;
  }
  return slices.length - 1;
}
