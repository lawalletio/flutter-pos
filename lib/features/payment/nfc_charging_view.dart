import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Full-screen animation shown while a tapped NFC card payment is being pulled.
///
/// The parent owns the payment lifecycle and rebuilds this widget with updated
/// [progress], [currentStep] and [amountLabel] as the charge advances.
///
/// * A central contactless icon breathes and emits continuously animated
///   "signal" ripples.
/// * The [amountLabel] + an animated progress bar.
/// * A live **task checklist** ([steps]): each task ticks off with a pop as it
///   completes, the active one shows a spinner, pending ones stay dimmed.
/// * A shimmering promo placeholder ("Surprise coming here…") for future perks.
class NfcChargingView extends StatefulWidget {
  const NfcChargingView({
    super.key,
    required this.progress, // 0.0 .. 1.0 overall progress
    required this.steps, // ordered task labels
    required this.currentStep, // index of the active task (done = < current)
    required this.amountLabel, // e.g. "12.500 sats · ≈ 11.800 ARS"
  });

  final double progress;
  final List<String> steps;
  final int currentStep;
  final String amountLabel;

  @override
  State<NfcChargingView> createState() => _NfcChargingViewState();
}

class _NfcChargingViewState extends State<NfcChargingView>
    with TickerProviderStateMixin {
  late final AnimationController _wave; // ripples + icon breathing
  late final AnimationController _shimmer; // promo sheen

  @override
  void initState() {
    super.initState();
    _wave = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
    _shimmer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
  }

  @override
  void dispose() {
    _wave.dispose();
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.progress.clamp(0.0, 1.0);

    return ColoredBox(
      color: AppColors.background,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _NfcPulse(controller: _wave),
                const SizedBox(height: 32),
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
                const SizedBox(height: 22),
                _ProgressBar(value: progress),
                const SizedBox(height: 24),
                // Live task checklist.
                Column(
                  children: [
                    for (var i = 0; i < widget.steps.length; i++) ...[
                      _TaskRow(
                        label: widget.steps[i],
                        state: i < widget.currentStep
                            ? _TaskState.done
                            : i == widget.currentStep
                                ? _TaskState.active
                                : _TaskState.pending,
                      ),
                      if (i != widget.steps.length - 1)
                        const SizedBox(height: 14),
                    ],
                  ],
                ),
                const SizedBox(height: 26),
                _PromoTeaser(shimmer: _shimmer),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The visual state of a single checklist task.
enum _TaskState { pending, active, done }

/// A checklist row whose leading marker animates between pending → active
/// (spinner) → done (a checkmark that pops in), with the label brightening.
class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.label, required this.state});

  final String label;
  final _TaskState state;

  @override
  Widget build(BuildContext context) {
    final isActive = state == _TaskState.active;
    final isDone = state == _TaskState.done;
    return Row(
      children: [
        SizedBox(
          width: 24,
          height: 24,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 340),
            transitionBuilder: (child, anim) => ScaleTransition(
              scale: CurvedAnimation(parent: anim, curve: Curves.easeOutBack),
              child: FadeTransition(opacity: anim, child: child),
            ),
            child: _marker(),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 300),
            style: TextStyle(
              color: isActive
                  ? AppColors.onDark
                  : isDone
                      ? AppColors.muted
                      : AppColors.muted.withValues(alpha: 0.5),
              fontSize: 16,
              fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
            ),
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
    );
  }

  Widget _marker() {
    switch (state) {
      case _TaskState.done:
        return Container(
          key: const ValueKey('done'),
          width: 24,
          height: 24,
          decoration: const BoxDecoration(
            color: AppColors.primary,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.check_rounded, size: 16, color: AppColors.onDark),
        );
      case _TaskState.active:
        return const SizedBox(
          key: ValueKey('active'),
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2.6,
            valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
          ),
        );
      case _TaskState.pending:
        return Container(
          key: const ValueKey('pending'),
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: AppColors.muted.withValues(alpha: 0.4),
              width: 2,
            ),
          ),
        );
    }
  }
}

/// A placeholder card for future promotions with a light "shimmer" sweeping
/// across the gift icon + text, hinting there's something to discover.
class _PromoTeaser extends StatelessWidget {
  const _PromoTeaser({required this.shimmer});

  final AnimationController shimmer;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
      ),
      child: AnimatedBuilder(
        animation: shimmer,
        builder: (context, child) {
          final t = shimmer.value;
          return ShaderMask(
            blendMode: BlendMode.srcIn,
            shaderCallback: (rect) => LinearGradient(
              begin: Alignment(-1.3 + 2 * t, 0),
              end: Alignment(-0.7 + 2 * t, 0),
              colors: const [
                AppColors.muted,
                AppColors.primary,
                AppColors.muted,
              ],
              stops: const [0.0, 0.5, 1.0],
            ).createShader(rect),
            child: child,
          );
        },
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.card_giftcard_rounded, size: 20, color: Colors.white),
            SizedBox(width: 10),
            Flexible(
              child: Text(
                'Surprise coming here...',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The central contactless icon: a breathing plate surrounded by continuously
/// radiating, fading "signal" rings.
class _NfcPulse extends StatelessWidget {
  const _NfcPulse({required this.controller});

  final AnimationController controller;

  @override
  Widget build(BuildContext context) {
    const size = 184.0;

    return SizedBox(
      width: size,
      height: size,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, child) {
          // Gentle sinusoidal breathing for the central plate.
          final breathe =
              1.0 + 0.05 * math.sin(controller.value * 2 * math.pi);
          return Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                size: const Size.square(size),
                painter: _RipplePainter(progress: controller.value),
              ),
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primary.withValues(alpha: 0.14),
                ),
              ),
              Transform.scale(scale: breathe, child: child),
            ],
          );
        },
        child: Container(
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
      ),
    );
  }
}

/// Paints 3 staggered rings that expand from the centre and fade as they grow.
class _RipplePainter extends CustomPainter {
  _RipplePainter({required this.progress});

  final double progress; // 0.0 .. 1.0 (looping)

  static const int _ringCount = 3;
  static const double _minRadius = 44;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    for (var i = 0; i < _ringCount; i++) {
      final t = (progress + i / _ringCount) % 1.0;
      final radius = _minRadius + (maxRadius - _minRadius) * t;
      final opacity = (1.0 - t) * math.min(1.0, t * 6);
      if (opacity <= 0) continue;

      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
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

  final double value; // already clamped 0..1 by the caller

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: value),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      builder: (context, animatedValue, _) => ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: LinearProgressIndicator(
          value: animatedValue,
          minHeight: 10,
          backgroundColor: AppColors.surface,
          valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primary),
        ),
      ),
    );
  }
}
