import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// A polished full-screen animation shown while a tapped NFC card payment is
/// being pulled.
///
/// The parent owns the payment lifecycle and simply rebuilds this widget with
/// updated [progress], [step] and [amountLabel] values as the charge advances.
///
/// * A central contactless icon emits continuously animated concentric
///   "signal" ripples that expand and fade outward.
/// * Below it, the [amountLabel], an animated rounded progress bar reflecting
///   [progress], and the current [step] label (which cross-fades on change).
/// * A muted hint reminds the user not to remove the card.
class NfcChargingView extends StatefulWidget {
  const NfcChargingView({
    super.key,
    required this.progress, // 0.0 .. 1.0 overall progress
    required this.step, // current step label, e.g. "Leyendo tarjeta…"
    required this.amountLabel, // e.g. "12.500 sats · ≈ 11.800 ARS"
  });

  final double progress;
  final String step;
  final String amountLabel;

  @override
  State<NfcChargingView> createState() => _NfcChargingViewState();
}

class _NfcChargingViewState extends State<NfcChargingView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _waveController;

  @override
  void initState() {
    super.initState();
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void dispose() {
    _waveController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Guard against out-of-range inputs from the parent.
    final clampedProgress = widget.progress.clamp(0.0, 1.0);

    return ColoredBox(
      color: AppColors.background,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              _NfcPulse(controller: _waveController),
              const SizedBox(height: 48),
              Text(
                widget.amountLabel,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.onDark,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(height: 28),
              _ProgressBar(value: clampedProgress),
              const SizedBox(height: 20),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: child,
                ),
                child: Text(
                  widget.step,
                  // Key on the text so the switcher animates on label changes.
                  key: ValueKey<String>(widget.step),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.onDark,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'No retires la tarjeta',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.muted,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The central contactless icon surrounded by continuously radiating,
/// fading "signal" rings.
class _NfcPulse extends StatelessWidget {
  const _NfcPulse({required this.controller});

  final AnimationController controller;

  @override
  Widget build(BuildContext context) {
    const size = 200.0;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Expanding, fading concentric rings.
          AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              return CustomPaint(
                size: const Size.square(size),
                painter: _RipplePainter(progress: controller.value),
              );
            },
          ),
          // Soft static glow disc behind the icon.
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.primary.withValues(alpha: 0.14),
            ),
          ),
          // Icon plate.
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surface,
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.6),
                width: 1.5,
              ),
            ),
            alignment: Alignment.center,
            child: const Icon(
              Icons.contactless,
              size: 40,
              color: AppColors.primary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Paints 3 staggered rings that expand from the centre and fade as they grow,
/// producing a looping "signal" ripple effect.
class _RipplePainter extends CustomPainter {
  _RipplePainter({required this.progress});

  /// Drives the animation, in the range 0.0 .. 1.0 (looping).
  final double progress;

  static const int _ringCount = 3;
  static const double _minRadius = 44;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    for (var i = 0; i < _ringCount; i++) {
      // Stagger each ring evenly across the loop so they trail one another.
      final t = (progress + i / _ringCount) % 1.0;

      final radius = _minRadius + (maxRadius - _minRadius) * t;
      // Fade out as the ring expands; also ease-in at birth to avoid popping.
      final opacity = (1.0 - t) * math.min(1.0, t * 6);

      if (opacity <= 0) continue;

      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        // Thicker near the centre, thinning as it expands.
        ..strokeWidth = 3.0 * (1.0 - t) + 1.0
        ..color = AppColors.primary.withValues(alpha: 0.55 * opacity);

      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RipplePainter oldDelegate) =>
      oldDelegate.progress != progress;
}

/// A rounded progress bar that smoothly tweens whenever [value] changes.
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.value});

  /// Already clamped to 0.0 .. 1.0 by the caller.
  final double value;

  @override
  Widget build(BuildContext context) {
    const height = 10.0;
    const radius = Radius.circular(height / 2);

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: value),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      builder: (context, animatedValue, _) {
        return ClipRRect(
          borderRadius: const BorderRadius.all(radius),
          child: SizedBox(
            height: height,
            width: double.infinity,
            child: Stack(
              children: [
                // Track.
                const ColoredBox(color: AppColors.surface),
                // Fill.
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: animatedValue,
                  child: Container(
                    decoration: const BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.all(radius),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
