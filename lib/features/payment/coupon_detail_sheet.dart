import 'package:flutter/material.dart';

import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../data/coupon/coupon_service.dart';
import '../../domain/config/currencies.dart';
import '../../domain/config/formatter.dart';
import '../../domain/coupon/coupon.dart';

/// The applied coupon: what it is, what it took off, and the way out.
///
/// Returns true when the cashier chose to remove it.
Future<bool?> showCouponDetailSheet(
  BuildContext context, {
  required CouponInfo coupon,
  required List<DiscountEntry> entries,
  required int discountSats,
  required int grossSats,
}) =>
    showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.background,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _CouponDetail(
        coupon: coupon,
        entries: entries,
        discountSats: discountSats,
        grossSats: grossSats,
      ),
    );

class _CouponDetail extends StatelessWidget {
  const _CouponDetail({
    required this.coupon,
    required this.entries,
    required this.discountSats,
    required this.grossSats,
  });

  final CouponInfo coupon;
  final List<DiscountEntry> entries;
  final int discountSats;
  final int grossSats;

  String _sats(int v) => formatToPreference(Currency.sat, v);

  Future<void> _confirmRemove(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(context.tr('¿Quitar el cupón?')),
        // Said plainly, because it is not reversible: the claim endpoint
        // consumed the nonce and there is no un-claim. Removing it here
        // restores the full price and the customer is left with nothing.
        content: Text(context.tr(
            'Se cobra el precio completo. El cupón ya fue canjeado y no se puede volver a usar.')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(context.tr('Cancelar'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.tr('Quitar')),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final net = grossSats - discountSats;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.local_offer, color: AppColors.primary, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(coupon.name,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          if (coupon.description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(coupon.description,
                style: const TextStyle(color: AppColors.muted)),
          ],
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(12)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(describeBenefit(coupon.benefit),
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                // Per currency, because that is how the coupon was written: a
                // basket in pesos and dollars gets a row for each.
                for (final e in entries)
                  _Row(
                    label: context.tr('Descuento'),
                    value: '-${e.currency.code} '
                        '${formatToPreference(e.currency, e.amount)}',
                    highlight: true,
                  ),
                const Divider(height: 20, color: AppColors.muted),
                _Row(label: context.tr('Subtotal'), value: '${_sats(grossSats)} sats'),
                _Row(
                    label: context.tr('Descuento'),
                    value: '-${_sats(discountSats)} sats',
                    highlight: true),
                const SizedBox(height: 4),
                _Row(
                    label: context.tr('Total'),
                    value: '${_sats(net)} sats',
                    bold: true),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(context.tr('Cerrar')),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextButton(
                  onPressed: () => _confirmRemove(context),
                  child: Text(context.tr('Quitar cupón'),
                      style: const TextStyle(color: AppColors.error)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(
      {required this.label,
      required this.value,
      this.highlight = false,
      this.bold = false});
  final String label;
  final String value;
  final bool highlight;
  final bool bold;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: TextStyle(
                    color: bold ? null : AppColors.muted,
                    fontWeight: bold ? FontWeight.w700 : null)),
            Text(value,
                style: TextStyle(
                  color: highlight ? AppColors.primary : null,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
                  fontSize: bold ? 18 : null,
                )),
          ],
        ),
      );
}
