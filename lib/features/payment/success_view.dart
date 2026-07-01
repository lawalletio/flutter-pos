import 'dart:math';

import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';

/// Spectacular "payment credited" celebration: confetti burst + rain, an
/// elastic pop-in check circle with expanding ripples, a stroke-drawn checkmark,
/// and content that fades/slides up.
class PaymentSuccessView extends StatefulWidget {
  final String satsStr;
  final String arsStr;
  final VoidCallback onBack;
  const PaymentSuccessView({
    super.key,
    required this.satsStr,
    required this.arsStr,
    required this.onBack,
  });

  @override
  State<PaymentSuccessView> createState() => _PaymentSuccessViewState();
}

class _PaymentSuccessViewState extends State<PaymentSuccessView>
    with TickerProviderStateMixin {
  late final AnimationController _intro; // one-shot: circle + check + content
  late final AnimationController _pulse; // looping ripples + glow
  late final ConfettiController _burst; // center explosion
  late final ConfettiController _rainL; // top-left rain
  late final ConfettiController _rainR; // top-right rain

  late final Animation<double> _circleScale;
  late final Animation<double> _checkDraw;
  late final Animation<double> _contentT;

  static const _festive = [
    AppColors.primary,
    Color(0xFFFFD166),
    Color(0xFFFFFFFF),
    Color(0xFF06D6A0),
    Color(0xFF9B8CFF),
  ];

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400));
    _pulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1800))
      ..repeat();
    _burst = ConfettiController(duration: const Duration(milliseconds: 900));
    _rainL = ConfettiController(duration: const Duration(seconds: 3));
    _rainR = ConfettiController(duration: const Duration(seconds: 3));

    _circleScale = CurvedAnimation(
        parent: _intro,
        curve: const Interval(0.0, 0.55, curve: Curves.elasticOut));
    _checkDraw = CurvedAnimation(
        parent: _intro,
        curve: const Interval(0.45, 0.75, curve: Curves.easeInOut));
    _contentT = CurvedAnimation(
        parent: _intro,
        curve: const Interval(0.6, 1.0, curve: Curves.easeOut));

    // Kick off the show.
    HapticFeedback.heavyImpact();
    _intro.forward();
    _burst.play();
    _rainL.play();
    _rainR.play();
  }

  @override
  void dispose() {
    _intro.dispose();
    _pulse.dispose();
    _burst.dispose();
    _rainL.dispose();
    _rainR.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        // Confetti rain from the top corners.
        Align(
          alignment: Alignment.topLeft,
          child: ConfettiWidget(
            confettiController: _rainL,
            blastDirection: pi / 3,
            emissionFrequency: 0.04,
            numberOfParticles: 6,
            gravity: 0.25,
            maxBlastForce: 22,
            minBlastForce: 8,
            colors: _festive,
          ),
        ),
        Align(
          alignment: Alignment.topRight,
          child: ConfettiWidget(
            confettiController: _rainR,
            blastDirection: 2 * pi / 3,
            emissionFrequency: 0.04,
            numberOfParticles: 6,
            gravity: 0.25,
            maxBlastForce: 22,
            minBlastForce: 8,
            colors: _festive,
          ),
        ),
        // Main content.
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 200,
              height: 200,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Expanding ripples + soft glow behind the badge.
                  AnimatedBuilder(
                    animation: _pulse,
                    builder: (_, __) => CustomPaint(
                      size: const Size(200, 200),
                      painter: _RipplePainter(_pulse.value),
                    ),
                  ),
                  // Center burst emits from behind the badge.
                  ConfettiWidget(
                    confettiController: _burst,
                    blastDirectionality: BlastDirectionality.explosive,
                    numberOfParticles: 24,
                    maxBlastForce: 28,
                    minBlastForce: 12,
                    gravity: 0.3,
                    colors: _festive,
                  ),
                  // The badge: elastic pop-in circle + drawn check.
                  ScaleTransition(
                    scale: _circleScale,
                    child: Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.primary,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withValues(alpha: 0.55),
                            blurRadius: 36,
                            spreadRadius: 4,
                          ),
                        ],
                      ),
                      child: AnimatedBuilder(
                        animation: _checkDraw,
                        builder: (_, __) => CustomPaint(
                          painter: _CheckPainter(_checkDraw.value),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // Content fades + slides up.
            AnimatedBuilder(
              animation: _contentT,
              builder: (_, child) => Opacity(
                opacity: _contentT.value,
                child: Transform.translate(
                  offset: Offset(0, 24 * (1 - _contentT.value)),
                  child: child,
                ),
              ),
              child: Column(
                children: [
                  const Text('¡Pago acreditado!',
                      style:
                          TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 10),
                  Text('${widget.satsStr} sats',
                      style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primary)),
                  Text('≈ ${widget.arsStr} ARS',
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 14)),
                  const SizedBox(height: 36),
                  SizedBox(
                    width: 260,
                    child: FilledButton(
                      onPressed: widget.onBack,
                      child: const Text('Volver'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Concentric expanding rings + a soft radial glow, driven by a 0..1 phase.
class _RipplePainter extends CustomPainter {
  final double t;
  _RipplePainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);

    // Soft glow.
    final glow = Paint()
      ..shader = RadialGradient(
        colors: [
          AppColors.primary.withValues(alpha: 0.28),
          AppColors.primary.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: 100));
    canvas.drawCircle(center, 100, glow);

    // Three staggered rings expanding outward and fading.
    for (var i = 0; i < 3; i++) {
      final phase = (t + i / 3) % 1.0;
      final radius = 62 + phase * 42;
      final opacity = (1 - phase) * 0.5;
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = AppColors.primary.withValues(alpha: opacity);
      canvas.drawCircle(center, radius, ring);
    }
  }

  @override
  bool shouldRepaint(_RipplePainter old) => old.t != t;
}

/// Draws the checkmark stroke progressively (0..1).
class _CheckPainter extends CustomPainter {
  final double progress;
  _CheckPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final paint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path()
      ..moveTo(size.width * 0.28, size.height * 0.52)
      ..lineTo(size.width * 0.44, size.height * 0.68)
      ..lineTo(size.width * 0.74, size.height * 0.34);

    final metrics = path.computeMetrics().toList();
    final total = metrics.fold<double>(0, (s, m) => s + m.length);
    var remaining = total * progress;
    final out = Path();
    for (final m in metrics) {
      if (remaining <= 0) break;
      out.addPath(m.extractPath(0, remaining.clamp(0, m.length)), Offset.zero);
      remaining -= m.length;
    }
    canvas.drawPath(out, paint);
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.progress != progress;
}
