import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

import '../../core/i18n.dart';
import '../../core/theme.dart';

/// Cinematic NFC charge. The timeline is staged so the cashier always sees
/// the process moving; a real settlement disposes this widget and cuts it off.
///
/// 1. Enviando invoice — bar fills in 1.5s, then a green tick.
/// 2. Cobrando con BoltCard — bar fills in 3s, then a green tick.
/// 3. Detectando pago — bar climbs to 90% over ~8s and holds, with a looped spinner.
class NfcChargingView extends StatefulWidget {
  const NfcChargingView({super.key, required this.amountLabel});

  final String amountLabel;

  @override
  State<NfcChargingView> createState() => _NfcChargingViewState();
}

class _Beat {
  const _Beat(this.label, this.asset, this.loop, this.duration, this.end);
  final String label;
  final String asset;
  final bool loop;
  final Duration duration;
  final double end;
}

const _beats = <_Beat>[
  _Beat('Enviando invoice', 'assets/lottie/send_invoice.json', false,
      Duration(milliseconds: 1500), 1),
  _Beat('Cobrando con BoltCard', 'assets/lottie/boltcard.json', true,
      Duration(seconds: 3), 1),
  _Beat('Detectando pago…', 'assets/lottie/spinner.json', true,
      Duration(seconds: 8), 0.9),
];

class _NfcChargingViewState extends State<NfcChargingView>
    with TickerProviderStateMixin {
  late final AnimationController _bar;
  late final AnimationController _shimmer;
  var _step = 0;
  var _tick = false;
  var _hold = false;
  var _alive = true;

  @override
  void initState() {
    super.initState();
    _bar = AnimationController(vsync: this);
    _shimmer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_alive) _play();
    });
  }

  Future<void> _play() async {
    for (var i = 0; i < _beats.length; i++) {
      if (!_alive) return;
      final beat = _beats[i];
      setState(() {
        _step = i;
        _tick = false;
        _hold = false;
      });
      _bar.duration = beat.duration;
      _bar.value = 0;
      try {
        await _bar.animateTo(
          beat.end,
          curve: i == 2 ? Curves.easeOut : Curves.easeOutCubic,
        );
      } on TickerCanceled {
        return;
      }
      if (!_alive) return;
      if (i < _beats.length - 1) {
        setState(() => _tick = true);
        await Future<void>.delayed(const Duration(milliseconds: 620));
      } else {
        setState(() => _hold = true);
        _shimmer.repeat();
      }
    }
  }

  @override
  void dispose() {
    _alive = false;
    _bar.dispose();
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final beat = _beats[_step];
    return ColoredBox(
      color: AppColors.background,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 20, 32, 28),
          child: Column(
            children: [
              const Spacer(flex: 2),
              _StepMeter(step: _step, confirmed: _tick),
              const SizedBox(height: 36),
              _Stage(beat: beat, tick: _tick),
              const SizedBox(height: 32),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeIn,
                child: Text(
                  context.tr(beat.label),
                  key: ValueKey(beat.label),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.onDark,
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                    height: 1.15,
                  ),
                ),
              ),
              const SizedBox(height: 22),
              _Bar(
                progress: _bar,
                shimmer: _hold ? _shimmer : null,
              ),
              const Spacer(flex: 3),
              Text(
                widget.amountLabel,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepMeter extends StatelessWidget {
  const _StepMeter({required this.step, required this.confirmed});

  final int step;
  final bool confirmed;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < _beats.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          AnimatedContainer(
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            width: i == step ? 36 : 10,
            height: 6,
            decoration: BoxDecoration(
              color: i > step
                  ? AppColors.surface
                  : AppColors.primary.withValues(
                      alpha: i == step && !confirmed ? 0.55 : 1,
                    ),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ],
      ],
    );
  }
}

class _Stage extends StatelessWidget {
  const _Stage({required this.beat, required this.tick});

  final _Beat beat;
  final bool tick;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 280,
      height: 280,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              AppColors.primary.withValues(alpha: 0.16),
              AppColors.primary.withValues(alpha: 0),
            ],
            stops: const [0.2, 0.72],
          ),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeIn,
          child: tick
              ? Lottie.asset(
                  'assets/lottie/tick.json',
                  key: const ValueKey('tick'),
                  repeat: false,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                )
              : Lottie.asset(
                  beat.asset,
                  key: ValueKey(beat.asset),
                  repeat: beat.loop,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                ),
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.progress, required this.shimmer});

  final Animation<double> progress;
  final Animation<double>? shimmer;

  @override
  Widget build(BuildContext context) {
    final animation = shimmer == null
        ? progress
        : Listenable.merge([progress, shimmer!]);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) => SizedBox(
        height: 14,
        width: double.infinity,
        child: CustomPaint(
          painter: _BarPainter(
            progress.value,
            shimmer?.value,
          ),
        ),
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter(this.t, this.shimmer);

  final double t;
  final double? shimmer;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.height / 2);
    final track = RRect.fromRectAndRadius(Offset.zero & size, radius);
    canvas.drawRRect(track, Paint()..color = AppColors.surface);

    final width = (size.width * t.clamp(0.0, 1.0));
    if (width <= 0) return;
    final fill = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, width, size.height),
      radius,
    );
    canvas.drawRRect(
      fill,
      Paint()
        ..color = AppColors.primary.withValues(alpha: 0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawRRect(fill, Paint()..color = AppColors.primary);

    final sweep = shimmer;
    if (sweep == null) return;
    canvas.save();
    canvas.clipRRect(fill);
    final band = 56.0;
    final x = (width + band) * sweep - band;
    canvas.drawRect(
      Rect.fromLTWH(x, 0, band * 0.42, size.height),
      Paint()..color = const Color(0x66FFFFFF),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BarPainter old) =>
      old.t != t || old.shimmer != shimmer;
}
