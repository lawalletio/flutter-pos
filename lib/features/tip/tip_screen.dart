import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/pricing/pricing_service.dart';
import '../../domain/config/currencies.dart';
import '../../domain/config/formatter.dart';

/// Tip — optional 5/10/15% (or skip) before payment. Mirrors the webapp `/tip`.
class TipScreen extends StatelessWidget {
  final int amountSats;
  final String? back;
  const TipScreen({super.key, required this.amountSats, this.back});

  static const _options = [5, 10, 15];

  String _ars(int sats) => formatToPreference(
      Currency.ars, pricing.satsToFiat(sats, Currency.ars) ?? 0);

  void _go(BuildContext context, int finalSats) {
    final b = back == null ? '' : '&back=${Uri.encodeComponent(back!)}';
    context.push('/payment?sats=$finalSats$b');
  }

  @override
  Widget build(BuildContext context) {
    pricing.ensureLoaded();
    return Scaffold(
      appBar: PosAppBar(title: context.tr('Propina')),
      body: ValueListenableBuilder<Rates?>(
        valueListenable: pricing.notifier,
        builder: (context, _, __) => PosBody(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            Text(context.tr('¿Cuánto dejás de propina?'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12)),
              child: Column(
                children: [
                  Text(context.tr('Total sin propina'),
                      style: const TextStyle(color: AppColors.muted)),
                  const SizedBox(height: 4),
                  Text('${formatToPreference(Currency.sat, amountSats)} sats',
                      style: const TextStyle(
                          fontSize: 26, fontWeight: FontWeight.w700)),
                  Text('≈ ${_ars(amountSats)} ARS',
                      style: const TextStyle(color: AppColors.muted)),
                ],
              ),
            ),
            const SizedBox(height: 20),
            for (final pct in _options) ...[
              _TipButton(
                label:
                    '$pct%  ·  ${formatToPreference(Currency.sat, (amountSats * (1 + pct / 100)).round())} sats',
                onTap: () => _go(context, (amountSats * (1 + pct / 100)).round()),
              ),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => _go(context, amountSats),
              child: Text(context.tr('NO QUIERO DEJAR PROPINA'),
                  style: const TextStyle(color: AppColors.muted)),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

class _TipButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _TipButton({required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Center(
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      );
}
