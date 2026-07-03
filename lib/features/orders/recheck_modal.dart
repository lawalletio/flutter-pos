import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../data/lnurl/lnurl_service.dart';
import '../../data/nostr/relay_pool.dart';
import '../../domain/order/orders_store.dart';

/// Amber used for the "still pending" result state.
const Color _kPendingAmber = Color(0xFFE0A82E);

/// Opens a polished animated modal that re-verifies whether a pending [order]
/// was actually paid — first via LUD-21 (`verify`), then via a short NIP-57 zap
/// receipt watch — surfacing each step with a radar animation and progress bar.
///
/// The barrier is not dismissible while the check runs; once finished the user
/// gets a "Cerrar" button. On a confirmed payment the order is marked paid in
/// [ordersStore].
Future<void> showRecheckModal(BuildContext context, OrderRecord order) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _RecheckDialog(order: order),
  );
}

class _RecheckDialog extends StatefulWidget {
  const _RecheckDialog({required this.order});

  final OrderRecord order;

  @override
  State<_RecheckDialog> createState() => _RecheckDialogState();
}

/// The visual/logical phase of the recheck flow.
enum _Phase { running, success, pending }

class _RecheckDialogState extends State<_RecheckDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _radar;
  ZapWatcher? _watcher;

  _Phase _phase = _Phase.running;
  double _progress = 0.0;
  String _step = '';

  @override
  void initState() {
    super.initState();
    _radar = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    // Kick off the async verification sequence after the first frame so the
    // dialog is on screen (and `context` usable) before we start.
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    if (!mounted) return;
    final order = widget.order;
    bool paid = false;

    // 1) LUD-21 verify URL.
    if (order.supportsLud21) {
      _set(step: context.tr('Verificando pago (LUD-21)…'), progress: 0.35);
      try {
        paid = await lnurl.checkSettled(order.verifyUrl!);
      } catch (_) {
        paid = false;
      }
    }

    // 2) NIP-57 zap receipt (only if not already confirmed).
    if (!paid && mounted && order.supportsNip57) {
      _set(step: context.tr('Verificando zap Nostr (NIP-57)…'), progress: 0.7);
      paid = await _watchZap(order);
    }

    if (!mounted) return;

    // 3) Finalize.
    _set(progress: 1.0);
    if (paid) {
      await ordersStore.markPaid(order.id);
      if (!mounted) return;
      _set(phase: _Phase.success, step: context.tr('¡Pago confirmado!'));
    } else {
      _set(phase: _Phase.pending, step: context.tr('Todavía sin confirmar'));
    }
  }

  /// Watch for a zap receipt for up to 8s; returns whether one arrived.
  Future<bool> _watchZap(OrderRecord order) async {
    final c = Completer<bool>();
    final w = ZapWatcher(
      relays: order.zapRelays,
      zapperPubkey: order.zapPubkey!,
      invoice: order.invoice!,
      orderId: order.zapOrderId,
      onPaid: () {
        if (!c.isCompleted) c.complete(true);
      },
    )..start();
    _watcher = w;
    // Creep the bar forward during the watch so it keeps advancing.
    final ticker = Timer.periodic(const Duration(milliseconds: 400), (t) {
      if (!mounted || c.isCompleted) {
        t.cancel();
        return;
      }
      _set(progress: (_progress + 0.025).clamp(0.0, 0.95));
    });
    final result =
        await c.future.timeout(const Duration(seconds: 8), onTimeout: () => false);
    ticker.cancel();
    w.dispose();
    if (identical(_watcher, w)) _watcher = null;
    return result;
  }

  /// Guarded `setState` — no-ops after dispose.
  void _set({_Phase? phase, double? progress, String? step}) {
    if (!mounted) return;
    setState(() {
      if (phase != null) _phase = phase;
      if (progress != null) _progress = progress;
      if (step != null) _step = step;
    });
    if (phase != null && phase != _Phase.running && _radar.isAnimating) {
      _radar.stop();
    }
  }

  @override
  void dispose() {
    _watcher?.dispose();
    _watcher = null;
    _radar.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final finished = _phase != _Phase.running;
    return Dialog(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 260, maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.tr('Reverificando pago…'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.onDark,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 20),
              _Glyph(phase: _phase, radar: _radar),
              const SizedBox(height: 18),
              Text(
                '${widget.order.amountSats} sats',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 20),
              // Progress bar — removed once the process finishes unconfirmed.
              if (_phase != _Phase.pending) ...[
                _ProgressBar(value: _progress, phase: _phase),
                const SizedBox(height: 16),
              ],
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(
                  _step,
                  key: ValueKey<String>(_step),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _stepColor(),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: finished
                    ? SizedBox(
                        key: const ValueKey('close'),
                        width: double.infinity,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: AppColors.onDark,
                            minimumSize: const Size.fromHeight(52),
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(context.tr('Cerrar')),
                        ),
                      )
                    : const SizedBox(
                        key: ValueKey('spacer'), height: 52, width: double.infinity),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _stepColor() {
    switch (_phase) {
      case _Phase.success:
        return AppColors.primary;
      case _Phase.pending:
        return _kPendingAmber;
      case _Phase.running:
        return AppColors.muted;
    }
  }
}

/// The top glyph: a radar sweep while running, cross-fading to a result icon.
class _Glyph extends StatelessWidget {
  const _Glyph({required this.phase, required this.radar});

  final _Phase phase;
  final AnimationController radar;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      width: 96,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 400),
        transitionBuilder: (child, anim) =>
            ScaleTransition(scale: anim, child: FadeTransition(opacity: anim, child: child)),
        child: _child(),
      ),
    );
  }

  Widget _child() {
    switch (phase) {
      case _Phase.running:
        return _RadarGlyph(key: const ValueKey('radar'), radar: radar);
      case _Phase.success:
        return const Icon(
          Icons.check_circle,
          key: ValueKey('ok'),
          size: 84,
          color: AppColors.primary,
        );
      case _Phase.pending:
        return const Icon(
          Icons.warning_amber_rounded,
          key: ValueKey('wait'),
          size: 84,
          color: _kPendingAmber,
        );
    }
  }
}

/// Concentric expanding rings + a sweeping arc around a central bolt glyph.
class _RadarGlyph extends StatelessWidget {
  const _RadarGlyph({super.key, required this.radar});

  final AnimationController radar;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: radar,
      builder: (context, child) => CustomPaint(
        painter: _RadarPainter(radar.value, AppColors.primary),
        child: child,
      ),
      child: const Center(
        child: Icon(Icons.bolt, size: 34, color: AppColors.primary),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter(this.t, this.color);

  final double t; // 0..1 repeating
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.shortestSide / 2;

    // Expanding, fading rings — three of them staggered by phase.
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    for (var i = 0; i < 3; i++) {
      final phase = (t + i / 3) % 1.0;
      final r = maxR * (0.25 + 0.75 * phase);
      final opacity = (1.0 - phase).clamp(0.0, 1.0) * 0.6;
      ring.color = color.withValues(alpha: opacity);
      canvas.drawCircle(center, r, ring);
    }

    // Static faint base ring.
    canvas.drawCircle(
      center,
      maxR * 0.94,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = color.withValues(alpha: 0.18),
    );

    // Sweeping arc that rotates once per cycle.
    final sweep = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.85);
    final start = t * 2 * math.pi;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: maxR * 0.94),
      start,
      math.pi / 3, // 60° arc
      false,
      sweep,
    );
  }

  @override
  bool shouldRepaint(covariant _RadarPainter old) =>
      old.t != t || old.color != color;
}

/// Rounded track whose fill eases smoothly toward [value] (0..1).
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.value, required this.phase});

  final double value;
  final _Phase phase;

  @override
  Widget build(BuildContext context) {
    final Color fill =
        phase == _Phase.pending ? _kPendingAmber : AppColors.primary;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: value.clamp(0.0, 1.0)),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
      builder: (context, v, _) => ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: LinearProgressIndicator(
          value: v,
          minHeight: 10,
          backgroundColor: AppColors.background,
          valueColor: AlwaysStoppedAnimation<Color>(fill),
        ),
      ),
    );
  }
}
