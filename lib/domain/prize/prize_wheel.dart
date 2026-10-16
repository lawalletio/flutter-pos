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

/// Slowest release, in turns per second, that counts as a spin. A gentler
/// throw coasts to a stop and asks for a harder one.
const kWheelMinFlingTurns = 0.9;

/// Faster releases launch as if they were this fast.
const kWheelMaxFlingTurns = 4.0;

/// Seconds the wheel takes to go from the finger's speed to the launch speed.
const kWheelLaunchSeconds = 0.16;

bool wheelFlingCounts(double radiansPerSecond) =>
    radiansPerSecond.abs() >= kWheelMinFlingTurns * 2 * math.pi;

/// Fraction of the wheel under the top pointer once it has turned [angle]
/// radians clockwise.
double wheelFractionAt(double angle) => (-angle / (2 * math.pi)) % 1;

/// One throw, from the release to the stop. The result is drawn before the
/// wheel moves; the motion only has to look like the finger caused it.
///
/// Speed starts at the finger's, eases for [ramp] seconds to [launch], then
/// decays as `(1 - t)^power`, which stops dead at [seconds] on the target.
class WheelThrow {
  const WheelThrow({
    required this.from,
    required this.direction,
    required this.fling,
    required this.launch,
    required this.ramp,
    required this.seconds,
    required this.power,
    required this.distance,
  });

  final double from;
  final double direction;
  final double fling;
  final double launch;
  final double ramp;
  final double seconds;
  final double power;
  final double distance;

  double get _rampDistance => (fling + launch) / 2 * ramp;

  /// Radians covered after [t] seconds, always positive.
  double travelled(double t) {
    if (t <= 0) return 0;
    if (t >= seconds) return distance;
    if (t <= ramp) return fling * t + (launch - fling) * t * t / (2 * ramp);
    final span = seconds - ramp;
    final left = 1 - (t - ramp) / span;
    return _rampDistance +
        launch * span / (power + 1) * (1 - math.pow(left, power + 1));
  }

  double angleAt(double t) => from + direction * travelled(t);

  /// Radians per second at [t], always positive.
  double speedAt(double t) {
    if (t <= 0) return fling;
    if (t >= seconds) return 0;
    if (t <= ramp) return fling + (launch - fling) * t / ramp;
    final left = 1 - (t - ramp) / (seconds - ramp);
    return launch * math.pow(left, power).toDouble();
  }
}

/// Plans a throw released at [velocity] (radians per second, clockwise
/// positive) that stops with [target] under the pointer.
///
/// [durationMs] is the spin length the merchant picked; a harder throw runs a
/// bit longer. [speed] scales the launch, [acceleration] how early it brakes.
WheelThrow planWheelThrow({
  required double angle,
  required double velocity,
  required double target,
  required int durationMs,
  double speed = 1,
  double acceleration = 1,
}) {
  const turn = 2 * math.pi;
  final direction = velocity < 0 ? -1.0 : 1.0;
  final fling = velocity.abs();
  const slowest = kWheelMinFlingTurns * turn;
  const fastest = kWheelMaxFlingTurns * turn;
  final clamped = fling.clamp(slowest, fastest);
  final strength = (clamped - slowest) / (fastest - slowest);
  final launch = clamped * clampWheelPace(speed);
  const ramp = kWheelLaunchSeconds;
  final rampDistance = (fling + launch) / 2 * ramp;
  final ideal = clampWheelDurationMs(durationMs) / 1000 * (0.85 + 0.3 * strength);
  final idealPower = 1 + 1.4 * clampWheelPace(acceleration);
  // Turning clockwise, the fraction under the pointer goes down.
  final now = wheelFractionAt(angle);
  final gap = (direction > 0 ? now - target : target - now) % 1 * turn;
  final wanted = rampDistance + launch * (ideal - ramp) / (idealPower + 1);
  final laps = math.max(0, ((wanted - gap) / turn).round());
  var distance = gap + laps * turn;
  while (distance - rampDistance < math.pi) {
    distance += turn;
  }
  final coast = distance - rampDistance;
  final power = (launch * (ideal - ramp) / coast - 1).clamp(1.2, 5.0);
  return WheelThrow(
    from: angle,
    direction: direction,
    fling: fling,
    launch: launch,
    ramp: ramp,
    seconds: ramp + coast * (power + 1) / launch,
    power: power,
    distance: distance,
  );
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
