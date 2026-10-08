import 'dart:math' as math;


import '../../core/checkout.dart';
import '../../core/i18n.dart';
import '../../core/sounds.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../core/widgets.dart';
import '../../data/pricing/pricing_service.dart';
import '../../domain/config/currencies.dart';
import '../../domain/config/formatter.dart';
import '../../domain/config/settings_state.dart';
import '../../domain/prize/prize_wheel.dart';

/// Tip — optional 5/10/15% (or skip) before payment. Mirrors the webapp `/tip`.
class TipScreen extends StatelessWidget {
  final int amountSats;
  final String? back;
  const TipScreen({super.key, required this.amountSats, this.back});

  static const _options = [5, 10, 15];

  String _ars(int sats) => formatToPreference(
      Currency.ars, pricing.satsToFiat(sats, Currency.ars) ?? 0);

  /// [finalSats] includes the tip; [finalSats] − [amountSats] IS the tip, and
  /// it travels explicitly. A coupon discounts the goods, never the tip, and
  /// the payment screen cannot tell the two apart from one total.
  void _go(BuildContext context, int finalSats) {
    final b = back == null ? '' : '&back=${Uri.encodeComponent(back!)}';
    final tip = finalSats - amountSats;
    pushCheckout(
        context, '/payment?sats=$finalSats${tip > 0 ? '&tip=$tip' : ''}$b');
  }

  int _withTip(int pct) => (amountSats * (1 + pct / 100)).round();

  bool _unlocksWheel(int tipSats) {
    final settings = appSettings.value;
    return offerWheelSpin(
      prizesEnabled: settings.prizePrintEnabled,
      hasPrizes: wheelHasPrizes(settings.prizeCoupons),
      offer: settings.wheelOffer,
      tipSats: tipSats,
    );
  }

  @override
  Widget build(BuildContext context) {
    pricing.ensureLoaded();
    return Scaffold(
      appBar: PosAppBar(title: context.tr('Propina')),
      body: ValueListenableBuilder<Rates?>(
        valueListenable: pricing.notifier,
        builder: (context, _, __) => ValueListenableBuilder<SettingsState>(
          valueListenable: appSettings,
          builder: (context, _, __) => PosBody(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 4),
                Text(context.tr('¿Cuánto dejás de propina?'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w800, height: 1.2)),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: const Color(0x14FFFFFF)),
                  ),
                  child: Column(
                    children: [
                      Text(context.tr('Total sin propina'),
                          style: const TextStyle(
                              color: AppColors.muted, fontSize: 13)),
                      const SizedBox(height: 6),
                      Text('${formatToPreference(Currency.sat, amountSats)} sats',
                          style: const TextStyle(
                              fontSize: 28, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Text('≈ ${_ars(amountSats)} ARS',
                          style: const TextStyle(color: AppColors.muted)),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                for (final pct in _options) ...[
                  _TipOption(
                    percent: pct,
                    tipSats: _withTip(pct) - amountSats,
                    totalSats: _withTip(pct),
                    totalArs: _ars(_withTip(pct)),
                    showWheel: _unlocksWheel(_withTip(pct) - amountSats),
                    onTap: () {
                      if (pct == 15) AppSounds.play(AppSound.tip15);
                      _go(context, _withTip(pct));
                    },
                  ),
                  const SizedBox(height: 10),
                ],
                const SizedBox(height: 6),
                _SkipTip(onTap: () => _go(context, amountSats)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TipOption extends StatelessWidget {
  const _TipOption({
    required this.percent,
    required this.tipSats,
    required this.totalSats,
    required this.totalArs,
    required this.showWheel,
    required this.onTap,
  });

  final int percent;
  final int tipSats;
  final int totalSats;
  final String totalArs;
  final bool showWheel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Row(
            children: [
              Container(
                width: 58,
                height: 58,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text('$percent%',
                    style: const TextStyle(
                        color: AppColors.primary,
                        fontSize: 18,
                        fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '+${formatToPreference(Currency.sat, tipSats)} sats',
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${formatToPreference(Currency.sat, totalSats)} sats  ·  ≈ $totalArs ARS',
                      style: const TextStyle(color: AppColors.muted, fontSize: 13),
                    ),
                  ],
                ),
              ),
              if (showWheel) ...[
                const SizedBox(width: 8),
                const _RouletteBadge(),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SkipTip extends StatelessWidget {
  const _SkipTip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: AppColors.muted,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const _SadFace(key: Key('tip-sad')),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              context.tr('NO QUIERO DEJAR PROPINA'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _SadFace extends StatelessWidget {
  const _SadFace({super.key});

  @override
  Widget build(BuildContext context) {
    return const Icon(
      Icons.sentiment_dissatisfied,
      size: 22,
      color: Color(0xFFFFC300),
    );
  }
}

class _RouletteBadge extends StatelessWidget {
  const _RouletteBadge();

  @override
  Widget build(BuildContext context) {
    const size = 36.0;
    return SizedBox(
      key: const Key('tip-roulette'),
      width: size,
      height: size,
      child: CustomPaint(painter: _MiniWheelPainter()),
    );
  }
}

class _MiniWheelPainter extends CustomPainter {
  const _MiniWheelPainter();

  static const _colors = <Color>[
    Color(0xFFFF2D55),
    Color(0xFFFFC300),
    Color(0xFF2EE59D),
    Color(0xFF3D8BFF),
    Color(0xFFB44CFF),
    Color(0xFFFF6A00),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2;
    canvas.drawCircle(c, radius, Paint()..color = const Color(0xFFFFD54A));
    final disc = radius - 2;
    final rect = Rect.fromCircle(center: c, radius: disc);
    final sweep = 2 * math.pi / _colors.length;
    for (var i = 0; i < _colors.length; i++) {
      canvas.drawArc(
        rect,
        -math.pi / 2 + i * sweep,
        sweep,
        true,
        Paint()..color = _colors[i],
      );
    }
    canvas.drawCircle(c, radius * 0.28, Paint()..color = const Color(0xFFFFF3B0));
    canvas.drawCircle(c, radius * 0.14, Paint()..color = const Color(0xFF1C1C1C));
    final pointer = Path()
      ..moveTo(c.dx, 0)
      ..lineTo(c.dx - radius * 0.16, radius * 0.34)
      ..lineTo(c.dx + radius * 0.16, radius * 0.34)
      ..close();
    canvas.drawPath(pointer, Paint()..color = const Color(0xFFFFF3B0));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
