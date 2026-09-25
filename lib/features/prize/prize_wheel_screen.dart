import 'dart:math' as math;

import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n.dart';
import '../../core/sounds.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../domain/config/settings_state.dart';
import '../../domain/order/order_reset.dart';
import '../../domain/order/receipt_printer.dart';
import '../../domain/prize/prize_wheel.dart';

const _palette = <Color>[
  Color(0xFFFF2D55),
  Color(0xFF2EE59D),
  Color(0xFF3D8BFF),
  Color(0xFFFFC300),
  Color(0xFFB44CFF),
  Color(0xFFFF6A00),
  Color(0xFF00D4FF),
  Color(0xFFFF4D8D),
];

const _missColor = Color(0xFF3A2B55);
const _gold = Color(0xFFFFD54A);
const _goldBright = Color(0xFFFFF3B0);
const _goldInk = Color(0xFF1C1C1C);
const _kHeartbeatLead = Duration(milliseconds: 2200);

/// Fortune wheel for the prize coupons. The pointer stays at the top; the
/// wheel starts fast, then coasts slowly enough to read each prize.
class PrizeWheelScreen extends StatefulWidget {
  const PrizeWheelScreen({
    super.key,
    this.coupons,
    this.singleSpin = false,
    this.returnTo,
    this.practice = false,
  });

  /// Coupons to draw. Defaults to the ones saved in settings.
  final List<PrizeCoupon>? coupons;

  /// One spin, then back. Used after a payment. The try button keeps replaying.
  final bool singleSpin;

  /// When set, back leaves the payment flow for this route instead of success.
  final String? returnTo;

  /// Opened from Configurar Ruleta. Shows the test badge and may skip printing.
  final bool practice;

  @override
  State<PrizeWheelScreen> createState() => _PrizeWheelScreenState();
}

enum _Phase { idle, spinning, settled }

class _PrizeWheelScreenState extends State<PrizeWheelScreen>
    with TickerProviderStateMixin {
  final _rng = math.Random();
  final _current = ValueNotifier<int>(0);

  late final AnimationController _spin;
  late final AnimationController _nudge;
  late final AnimationController _reveal;
  late final AnimationController _lights;
  late final AnimationController _heartbeat;
  late final ConfettiController _burst;
  late final ConfettiController _rain;
  late final List<WheelSlice> _slices;
  late final List<Color> _colors;

  _Phase _phase = _Phase.idle;
  double _targetTurns = 0;
  int _shown = 0;
  int _heard = 0;
  bool _printing = false;
  bool _printed = false;
  bool _built = false;
  double _laidDiameter = -1;
  List<_LaidLabel> _labels = const [];
  DateTime? _lastTick;
  bool _heartbeatOn = false;

  double get _turns => _wheelCurve.transform(_spin.value) * _targetTurns;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: kWheelDurationDefaultMs),
    )
      ..addListener(_onSpin)
      ..addStatusListener(_onStatus);
    _nudge = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 90),
    );
    _reveal = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _lights = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
    _heartbeat = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 720),
    );
    _burst = ConfettiController(duration: const Duration(milliseconds: 1600));
    _rain = ConfettiController(duration: const Duration(milliseconds: 2800));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_built) return;
    final coupons = widget.coupons ?? appSettings.value.prizeCoupons;
    _slices = distributeWheelSlices(buildWheelSlices(
      coupons,
      keepPlayingLabel: context.tr('Seguí participando'),
    ));
    final colorById = <String, Color>{};
    var prizeColor = 0;
    _colors = [
      for (final slice in _slices)
        colorById.putIfAbsent(slice.id, () {
          if (!slice.isPrize) return _missColor;
          return _palette[prizeColor++ % _palette.length];
        }),
    ];
    _built = true;
  }

  @override
  void dispose() {
    _disposeLabels();
    _stopBeds();
    _spin.dispose();
    _nudge.dispose();
    _reveal.dispose();
    _lights.dispose();
    _heartbeat.dispose();
    _burst.dispose();
    _rain.dispose();
    _current.dispose();
    super.dispose();
  }

  void _stopBeds() {
    AppSounds.stop(AppSound.casino);
    AppSounds.stop(AppSound.heartbeat);
    AppSounds.stop(AppSound.miss);
    _heartbeat
      ..stop()
      ..value = 0;
    _heartbeatOn = false;
  }

  void _disposeLabels() {
    for (final label in _labels) {
      label.dispose();
    }
  }

  /// Prize names are laid out once. The spin only moves those cached glyphs.
  void _layoutLabels(double diameter) {
    if (_laidDiameter == diameter) return;
    _disposeLabels();
    final total = wheelWeight(_slices);
    final next = <_LaidLabel>[];
    for (var i = 0; i < _slices.length; i++) {
      final fraction = _slices[i].weight / total;
      final width = _labelWidth(diameter, fraction);
      if (width < 28) continue;
      final font = (width / 3.4).clamp(10.0, 15.0);
      final painter = TextPainter(
        text: TextSpan(
          text: _slices[i].label.replaceAll('\n', ' ').trim(),
          style: TextStyle(
            color: Colors.white,
            fontSize: font,
            fontWeight: FontWeight.w800,
            height: 1.05,
            letterSpacing: 0.2,
            shadows: const [
              Shadow(
                color: Color(0xE6000000),
                blurRadius: 0,
                offset: Offset(0, 1),
              ),
            ],
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
        maxLines: 2,
        ellipsis: '…',
      )..layout(maxWidth: width);
      next.add(_LaidLabel(
        mid: _sliceMid(_slices, total, i),
        distance: _labelDistance(diameter, fraction),
        painter: painter,
      ));
    }
    _labels = next;
    _laidDiameter = diameter;
  }

  bool get _hasPrizes => _slices.any((slice) => slice.isPrize);

  void _start() {
    if (_phase == _Phase.spinning || !_hasPrizes) return;
    final index = pickSliceIndex(_slices, _rng.nextDouble());
    final fraction = landingFraction(_slices, index, _rng.nextDouble());
    final durationMs = appSettings.value.wheelDurationMs;
    _spin.duration = Duration(milliseconds: durationMs);
    _targetTurns = landingTurns(
      fraction,
      spins: wheelExtraSpins(
        durationMs,
        speed: appSettings.value.wheelSpeed,
      ),
    );
    _heard = _shown;
    _printing = false;
    _printed = false;
    _burst.stop();
    _rain.stop();
    _reveal.value = 0;
    _heartbeatOn = false;
    _heartbeat
      ..stop()
      ..value = 0;
    AppSounds.stop(AppSound.heartbeat);
    AppSounds.play(AppSound.casino, loop: true);
    setState(() => _phase = _Phase.spinning);
    // Start after the wheel has the new target, so the first frames don't
    // spin against the previous landing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _phase != _Phase.spinning) return;
      _spin.forward(from: 0);
    });
  }

  void _onSpin() {
    final index = sliceIndexAt(_slices, (-_turns) % 1);
    if (index != _heard) {
      _heard = index;
      if (_phase == _Phase.spinning) _peg();
    }
    if (index != _shown) {
      _shown = index;
      _current.value = index;
    }
    _maybeStartHeartbeat();
  }

  void _maybeStartHeartbeat() {
    if (_heartbeatOn || _phase != _Phase.spinning) return;
    final left = _spin.duration == null
        ? Duration.zero
        : _spin.duration! * (1 - _spin.value);
    if (left > _kHeartbeatLead) return;
    _heartbeatOn = true;
    AppSounds.stop(AppSound.casino);
    AppSounds.play(AppSound.heartbeat, loop: true);
    _heartbeat.repeat();
    HapticFeedback.mediumImpact();
  }

  /// One click per wedge, but never faster than the device can play it.
  void _peg() {
    final now = DateTime.now();
    final last = _lastTick;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 70)) {
      return;
    }
    _lastTick = now;
    AppSounds.play(AppSound.tick);
    if (!_nudge.isAnimating) _nudge.forward(from: 0);
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _phase != _Phase.spinning) {
      return;
    }
    final slice = _slices[_shown];
    final printTicket =
        !widget.practice || appSettings.value.wheelPracticePrint;
    _stopBeds();
    setState(() {
      _phase = _Phase.settled;
      if (slice.isPrize && printTicket) _printing = true;
      if (slice.isPrize && !printTicket) _printed = true;
    });
    if (!slice.isPrize) {
      AppSounds.play(AppSound.miss);
      HapticFeedback.mediumImpact();
      _reveal.forward(from: 0);
      return;
    }
    AppSounds.play(AppSound.win);
    HapticFeedback.heavyImpact();
    _reveal.forward(from: 0);
    _burst.play();
    _rain.play();
    if (printTicket) _claim();
  }

  Future<void> _claim() async {
    final prize = _slices[_shown].prize;
    if (prize == null || _printed) return;
    if (!_printing) setState(() => _printing = true);
    final res = await printPrizeCoupon(text: prize.text);
    if (!mounted) return;
    setState(() {
      _printing = false;
      if (res.ok) _printed = true;
    });
    if (res.ok) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(res.message),
      backgroundColor: AppColors.error,
    ));
  }

  void _leave() {
    AppSounds.stop(AppSound.win);
    AppSounds.stop(AppSound.miss);
    final destination = widget.returnTo;
    if (destination == null || destination.isEmpty) {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/hub');
      }
      return;
    }
    resetOrder();
    context.go(destination);
  }

  PreferredSizeWidget _bar({required bool leavePayment}) {
    return PosAppBar(
      title: context.tr('Ruleta'),
      showSettings: false,
      showSync: !widget.practice,
      showInvoiceDebug: !widget.practice,
      onBack: leavePayment ? _leave : null,
      actions: [
        if (widget.practice)
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Center(
              child: Text(
                context.tr('MODO PRUEBA'),
                style: const TextStyle(
                  color: Color(0xFFFF4D8D),
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final leavePayment = widget.returnTo != null && widget.returnTo!.isNotEmpty;
    if (!_hasPrizes) {
      return PopScope(
        canPop: !leavePayment,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _leave();
        },
        child: Scaffold(
          appBar: _bar(leavePayment: leavePayment),
          body: Center(
            child: Text(
              context.tr('No hay premios'),
              style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 22,
                  fontWeight: FontWeight.w700),
            ),
          ),
        ),
      );
    }
    final screen = MediaQuery.sizeOf(context);
    final diameter = math.min(screen.width - 48, 420.0);
    _layoutLabels(diameter);
    final slice = _slices[_shown];
    return PopScope(
      canPop: !leavePayment,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: _bar(leavePayment: leavePayment),
        body: Stack(
          children: [
            PosBody(
              child: Column(
                children: [
                  const Spacer(),
                  _Wheel(
                    diameter: diameter,
                    spin: _spin,
                    targetTurns: _targetTurns,
                    slices: _slices,
                    colors: _colors,
                    labels: _labels,
                    nudge: _nudge,
                    lights: _lights,
                    heartbeat: _heartbeat,
                    onTap: _phase == _Phase.spinning ||
                            (_phase == _Phase.settled &&
                                (slice.isPrize || widget.singleSpin))
                        ? null
                        : _start,
                  ),
                  const SizedBox(height: 28),
                  if (_phase == _Phase.spinning)
                    ValueListenableBuilder<int>(
                      valueListenable: _current,
                      builder: (context, index, _) => _Caption(
                        label: _slices[index].label,
                        color: _colors[index],
                        won: false,
                      ),
                    )
                  else
                    const SizedBox(height: 84),
                  const SizedBox(height: 18),
                  _actions(slice),
                  const Spacer(),
                ],
              ),
            ),
            IgnorePointer(
              child: Align(
                alignment: Alignment.center,
                child: ConfettiWidget(
                  confettiController: _burst,
                  canvas: screen,
                  blastDirectionality: BlastDirectionality.explosive,
                  numberOfParticles: 48,
                  maxBlastForce: 42,
                  minBlastForce: 18,
                  gravity: 0.18,
                  emissionFrequency: 0.05,
                  colors: _confettiColors,
                  createParticlePath: _confettiBit,
                ),
              ),
            ),
            IgnorePointer(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConfettiWidget(
                  confettiController: _rain,
                  canvas: screen,
                  blastDirection: math.pi / 2,
                  emissionFrequency: 0.05,
                  numberOfParticles: 14,
                  gravity: 0.22,
                  maxBlastForce: 22,
                  minBlastForce: 8,
                  colors: _confettiColors,
                ),
              ),
            ),
            if (_phase == _Phase.settled && slice.isPrize)
              Positioned.fill(
                child: _PrizeReveal(
                  animation: _reveal,
                  name: slice.label,
                  headline: context.tr('¡Ganaste un premio!'),
                  onTap: _leave,
                ),
              ),
            if (_phase == _Phase.settled && !slice.isPrize)
              _KeepPlayingReveal(
                animation: _reveal,
                label: context.tr('Seguí participando'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _actions(WheelSlice slice) {
    if (_phase == _Phase.spinning) {
      return const SizedBox(height: 74);
    }
    if (_phase == _Phase.settled && slice.isPrize) {
      if (_printing) {
        return const SizedBox(
          height: 74,
          child: Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.6, color: _gold),
            ),
          ),
        );
      }
      if (!_printed) {
        return SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _claim,
            style: FilledButton.styleFrom(
              backgroundColor: _gold,
              foregroundColor: _goldInk,
            ),
            child: Text(context.tr('RECLAMAR')),
          ),
        );
      }
      if (widget.singleSpin) return const SizedBox(height: 74);
      return TextButton(
        onPressed: _start,
        child: Text(context.tr('Otra vez')),
      );
    }
    if (widget.singleSpin && _phase == _Phase.settled) {
      return const SizedBox(height: 74);
    }
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: _start,
        child: Text(context.tr(_phase == _Phase.idle ? 'Girar' : 'Otra vez')),
      ),
    );
  }
}

const _confettiColors = <Color>[
  Color(0xFFFFD166),
  Color(0xFFFFF3B0),
  Color(0xFFC8102E),
  Color(0xFFFFFFFF),
  Color(0xFF56B68C),
  Color(0xFFFF4D8D),
];

Path _confettiBit(Size size) {
  final path = Path();
  path.addRRect(RRect.fromRectAndRadius(
    Rect.fromLTWH(0, 0, size.width, size.height * 0.45),
    const Radius.circular(1),
  ));
  return path;
}

const _wheelCurve = _WheelCurve();

class _WheelCurve extends Curve {
  const _WheelCurve();

  @override
  double transformInternal(double t) => wheelSpinProgress(
        t,
        acceleration: appSettings.value.wheelAcceleration,
      );
}

class _LaidLabel {
  _LaidLabel({
    required this.mid,
    required this.distance,
    required this.painter,
  });

  final double mid;
  final double distance;
  final TextPainter painter;

  void dispose() => painter.dispose();
}

class _Wheel extends StatelessWidget {
  const _Wheel({
    required this.diameter,
    required this.spin,
    required this.targetTurns,
    required this.slices,
    required this.colors,
    required this.labels,
    required this.nudge,
    required this.lights,
    required this.heartbeat,
    required this.onTap,
  });

  final double diameter;
  final AnimationController spin;
  final double targetTurns;
  final List<WheelSlice> slices;
  final List<Color> colors;
  final List<_LaidLabel> labels;
  final Animation<double> nudge;
  final Animation<double> lights;
  final Animation<double> heartbeat;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final face = RepaintBoundary(
      child: CustomPaint(
        isComplex: true,
        willChange: false,
        painter: _WheelFace(slices: slices, colors: colors),
        size: Size.square(diameter),
      ),
    );
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: heartbeat,
        builder: (context, child) {
          final beat = heartbeat.value;
          final pulse = beat <= 0
              ? 0.0
              : (math.sin(beat * math.pi * 2).clamp(0.0, 1.0) * 0.018);
          return Transform.scale(scale: 1 + pulse, child: child);
        },
        child: SizedBox(
          width: diameter,
          height: diameter + 28,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.topCenter,
            children: [
              Positioned(
                top: 22,
                width: diameter,
                height: diameter,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Color(0x99000000),
                        blurRadius: 22,
                        offset: Offset(0, 12),
                      ),
                    ],
                  ),
                  child: GestureDetector(
                    onTap: onTap,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        AnimatedBuilder(
                          animation: spin,
                          builder: (context, child) {
                            final angle = _wheelCurve.transform(spin.value) *
                                targetTurns *
                                2 *
                                math.pi;
                            return Transform.rotate(
                              angle: angle,
                              filterQuality: FilterQuality.none,
                              child: child,
                            );
                          },
                          child: face,
                        ),
                        IgnorePointer(
                          child: CustomPaint(
                            painter: _UprightLabels(
                              labels: labels,
                              spin: spin,
                              targetTurns: targetTurns,
                            ),
                            size: Size.square(diameter),
                          ),
                        ),
                        IgnorePointer(
                          child: CustomPaint(
                            painter: _RimLightsPainter(lights: lights),
                            size: Size.square(diameter),
                          ),
                        ),
                        _GlassShine(diameter: diameter),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                top: -4,
                child: CustomPaint(
                  painter: _PointerPainter(nudge: nudge),
                  size: const Size(56, 72),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

double _sliceMid(List<WheelSlice> slices, int total, int index) {
  var covered = 0;
  for (var i = 0; i < index; i++) {
    covered += slices[i].weight;
  }
  final start = covered / total;
  final sweep = slices[index].weight / total;
  return -math.pi / 2 + (start + sweep / 2) * 2 * math.pi;
}

/// Distance from the hub to the middle of the colored wedge.
double _labelDistance(double diameter, double fraction) {
  final radius = diameter / 2;
  final outer = radius - 28;
  final inner = radius * 0.20;
  final alpha = fraction * math.pi;
  if (alpha < 0.001) return (inner + outer) / 2;
  final factor = 2 * math.sin(alpha) / (3 * alpha);
  final span = (math.pow(outer, 3) - math.pow(inner, 3)) /
      (math.pow(outer, 2) - math.pow(inner, 2));
  return factor * span;
}

double _labelWidth(double diameter, double fraction) {
  final dist = _labelDistance(diameter, fraction);
  final sweep = fraction * 2 * math.pi;
  final chord = 2 * dist * math.sin(sweep / 2) * 0.82;
  return chord.clamp(0.0, diameter * 0.46);
}

/// Cached prize names. They follow the wheel without rebuilding widgets.
class _UprightLabels extends CustomPainter {
  _UprightLabels({
    required this.labels,
    required this.spin,
    required this.targetTurns,
  }) : super(repaint: spin);

  final List<_LaidLabel> labels;
  final Animation<double> spin;
  final double targetTurns;

  @override
  void paint(Canvas canvas, Size size) {
    if (labels.isEmpty) return;
    final angle = _wheelCurve.transform(spin.value) * targetTurns * 2 * math.pi;
    final cx = size.width / 2;
    final cy = size.height / 2;
    for (final label in labels) {
      final a = label.mid + angle;
      final dx = cx + math.cos(a) * label.distance;
      final dy = cy + math.sin(a) * label.distance;
      label.painter.paint(
        canvas,
        Offset(dx - label.painter.width / 2, dy - label.painter.height / 2),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _UprightLabels oldDelegate) =>
      oldDelegate.labels != labels ||
      oldDelegate.targetTurns != targetTurns ||
      oldDelegate.spin != spin;
}

class _GlassShine extends StatelessWidget {
  const _GlassShine({required this.diameter});

  final double diameter;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: const _GlassShinePainter(),
        size: Size.square(diameter),
      ),
    );
  }
}

class _RimLightsPainter extends CustomPainter {
  _RimLightsPainter({required this.lights}) : super(repaint: lights);

  final Animation<double> lights;
  static const _count = 24;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2;
    final t = lights.value;
    for (var i = 0; i < _count; i++) {
      final a = -math.pi / 2 + i * 2 * math.pi / _count;
      final at = c + Offset(math.cos(a), math.sin(a)) * (radius - 18);
      final wave = 0.5 + 0.5 * math.sin((t * 2 * math.pi) + i * 0.55);
      final lit = 0.28 + 0.72 * wave;
      canvas.drawCircle(
        at,
        4.8,
        Paint()..color = Color.lerp(const Color(0xFF6E5410), _goldBright, lit)!,
      );
      if (wave > 0.72) {
        canvas.drawCircle(
          at + const Offset(-1.2, -1.2),
          1.6,
          Paint()..color = const Color(0xCCFFFFFF),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _RimLightsPainter oldDelegate) =>
      oldDelegate.lights != lights;
}

class _GlassShinePainter extends CustomPainter {
  const _GlassShinePainter();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final c = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2;
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(-0.7);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(-radius * 0.08, -radius * 0.34),
        width: radius * 0.92,
        height: radius * 0.34,
      ),
      Paint()..color = const Color(0x28FFFFFF),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _PointerPainter extends CustomPainter {
  _PointerPainter({required this.nudge}) : super(repaint: nudge);

  final Animation<double> nudge;

  @override
  void paint(Canvas canvas, Size size) {
    final kick = math.sin(nudge.value * math.pi);
    canvas.save();
    canvas.translate(size.width / 2, 0);
    canvas.rotate(-0.22 * kick);
    canvas.translate(-size.width / 2, 0);
    final w = size.width;
    final h = size.height;
    final cap = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.22, 0, w * 0.56, 18),
      const Radius.circular(7),
    );
    canvas.drawRRect(cap, Paint()..color = const Color(0xFF6E5410));
    canvas.drawRRect(
      cap,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = _goldBright,
    );
    final tip = Path()
      ..moveTo(w / 2, h - 1)
      ..lineTo(w - 5, 16)
      ..quadraticBezierTo(w / 2, 6, 5, 16)
      ..close();
    canvas.drawPath(tip.shift(const Offset(0, 2)),
        Paint()..color = const Color(0x66000000));
    canvas.drawPath(tip, Paint()..color = _gold);
    final inner = Path()
      ..moveTo(w / 2, h - 12)
      ..lineTo(w * 0.70, 20)
      ..quadraticBezierTo(w / 2, 13, w * 0.30, 20)
      ..close();
    canvas.drawPath(inner, Paint()..color = const Color(0xFFB4232C));
    canvas.drawCircle(Offset(w / 2, 11), 5, Paint()..color = _goldBright);
    canvas.drawCircle(
        Offset(w / 2, 11), 2.4, Paint()..color = const Color(0xFFB4232C));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PointerPainter oldDelegate) =>
      oldDelegate.nudge != nudge;
}

class _WheelFace extends CustomPainter {
  const _WheelFace({required this.slices, required this.colors});

  final List<WheelSlice> slices;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final total = wheelWeight(slices);
    final radius = size.width / 2;
    final disc = radius - 28;
    final discRect = Rect.fromCircle(center: Offset.zero, radius: disc);
    canvas.save();
    canvas.translate(radius, radius);

    canvas.drawCircle(
        Offset.zero, radius, Paint()..color = const Color(0xFF2A1608));
    canvas.drawCircle(
      Offset.zero,
      radius - 2.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..color = _gold,
    );
    canvas.drawCircle(
        Offset.zero, radius - 11, Paint()..color = const Color(0xFF0B0712));

    const bulbs = 24;
    for (var i = 0; i < bulbs; i++) {
      final a = -math.pi / 2 + i * 2 * math.pi / bulbs;
      final at = Offset(math.cos(a), math.sin(a)) * (radius - 18);
      canvas.drawCircle(at, 7.2, Paint()..color = const Color(0xFF1A1208));
      canvas.drawCircle(at, 4.8, Paint()..color = const Color(0x66FFF3B0));
    }

    var start = -math.pi / 2;
    for (var i = 0; i < slices.length; i++) {
      final sweep = slices[i].weight / total * 2 * math.pi;
      canvas.drawArc(discRect, start, sweep, true, Paint()..color = colors[i]);
      start += sweep;
    }
    canvas.save();
    canvas.clipPath(Path()..addOval(discRect));
    canvas.drawRect(
      discRect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0x38FFFFFF),
            Color(0x00FFFFFF),
            Color(0x66000000),
          ],
          stops: [0.0, 0.42, 1.0],
        ).createShader(discRect),
    );
    canvas.restore();

    start = -math.pi / 2;
    final divider = Paint()
      ..color = const Color(0xF2FFF3B0)
      ..strokeWidth = 3;
    final hub = radius * 0.2;
    for (var i = 0; i < slices.length; i++) {
      final sweep = slices[i].weight / total * 2 * math.pi;
      final dir = Offset(math.cos(start), math.sin(start));
      canvas.drawLine(dir * hub, dir * disc, divider);
      start += sweep;
    }

    canvas.drawCircle(
      Offset.zero,
      disc,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = _gold,
    );
    canvas.drawCircle(Offset.zero, hub, Paint()..color = _gold);
    canvas.drawCircle(Offset.zero, hub - radius * 0.035,
        Paint()..color = const Color(0xFF140E08));
    final gem = radius * 0.055;
    final diamond = Path()
      ..moveTo(0, -gem)
      ..lineTo(gem * 0.72, 0)
      ..lineTo(0, gem)
      ..lineTo(-gem * 0.72, 0)
      ..close();
    canvas.drawPath(diamond, Paint()..color = AppColors.primary);
    canvas.drawPath(
      diamond,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..color = _goldBright,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WheelFace oldDelegate) =>
      oldDelegate.slices != slices || oldDelegate.colors != colors;
}

class _KeepPlayingReveal extends StatelessWidget {
  const _KeepPlayingReveal({
    required this.animation,
    required this.label,
  });

  final Animation<double> animation;
  final String label;

  @override
  Widget build(BuildContext context) {
    final parts = label.trim().split(RegExp(r'\s+'));
    final lead = parts.first;
    final rest = parts.skip(1).join(' ');
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          final t = animation.value;
          final slam = Curves.easeOutBack.transform(t);
          final fade = (t / 0.22).clamp(0.0, 1.0);
          final ring = Curves.easeOutCubic.transform(t);
          final ring2 = ((t - 0.18) / 0.82).clamp(0.0, 1.0);
          return Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(
                color: Color.fromRGBO(10, 4, 18, 0.78 * fade),
              ),
              Center(child: _missRing(ring, 0.55)),
              Center(child: _missRing(ring2, 0.35)),
              Center(
                child: Opacity(
                  opacity: fade,
                  child: Transform.scale(
                    scale: 1.42 - 0.42 * slam,
                    child: child,
                  ),
                ),
              ),
            ],
          );
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              lead,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 46,
                height: 0.95,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
            if (rest.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                rest,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFFFF4D8D),
                  fontSize: 34,
                  height: 1,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Container(
              width: 72,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFFF4D8D),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _missRing(double t, double alpha) {
    final fade = (1 - t).clamp(0.0, 1.0);
    return Opacity(
      opacity: fade * alpha,
      child: Transform.scale(
        scale: 0.45 + 1.15 * t,
        child: Container(
          width: 240,
          height: 240,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: const Color(0xFFFF4D8D),
              width: 3,
            ),
          ),
        ),
      ),
    );
  }
}

class _PrizeReveal extends StatelessWidget {
  const _PrizeReveal({
    required this.animation,
    required this.name,
    required this.headline,
    required this.onTap,
  });

  final Animation<double> animation;
  final String name;
  final String headline;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final title = name.replaceAll('\n', ' ').trim();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          final t = Curves.easeOutBack.transform(animation.value);
          final fade = (animation.value / 0.4).clamp(0.0, 1.0);
          return Opacity(
            opacity: fade,
            child: ColoredBox(
              color: const Color(0xB3000000),
              child: Center(
                child: Transform.scale(scale: 0.7 + 0.3 * t, child: child),
              ),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF1A140C),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: _gold, width: 3),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 28,
                  offset: Offset(0, 14),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 26, 28, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    headline,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: _goldBright,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 40,
                      height: 1.05,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Caption extends StatelessWidget {
  const _Caption({
    required this.label,
    required this.color,
    required this.won,
  });

  final String label;
  final Color color;
  final bool won;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 84),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: won ? const Color(0xFF3A3118) : AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: won ? _gold : color.withValues(alpha: 0.9),
          width: won ? 1.6 : 1.2,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (won) ...[
            Text(context.tr('¡Ganaste un premio!'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: _gold, fontSize: 14, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
          ],
          Row(
            children: [
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.start,
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w800, height: 1.15),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
