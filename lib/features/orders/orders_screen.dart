import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/pricing/pricing_service.dart';
import '../../domain/config/currencies.dart';
import '../../domain/config/formatter.dart';
import '../../domain/order/orders_store.dart';
import '../../domain/order/receipt_printer.dart';
import 'recheck_modal.dart';

const Color _amber = Color(0xFFE0A82E);
final DateFormat _df = DateFormat('dd/MM · HH:mm');

/// Orders — persisted payment history (empty on a fresh install). Paid orders
/// count toward the total sold; a **pending** order can be re-verified against
/// LUD-21 + NIP-57 via the recheck button.
class OrdersScreen extends StatelessWidget {
  const OrdersScreen({super.key});

  Future<void> _confirmDeleteAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(context.tr('¿Eliminar todas las órdenes?')),
        content: Text(context.tr(
            'Se borrará el historial de órdenes de esta sesión. '
            'Esta acción no se puede deshacer.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.tr('Cancelar'),
                style: const TextStyle(color: AppColors.muted)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.tr('Eliminar todas')),
          ),
        ],
      ),
    );
    if (ok == true) ordersStore.clear();
  }

  @override
  Widget build(BuildContext context) {
    pricing.ensureLoaded();
    return Scaffold(
      appBar: PosAppBar(title: context.tr('Órdenes')),
      body: ValueListenableBuilder<List<OrderRecord>>(
        valueListenable: ordersStore.notifier,
        builder: (context, orders, _) => ValueListenableBuilder<Rates?>(
          valueListenable: pricing.notifier,
          builder: (context, __, ___) => PosBody(
            child: orders.isEmpty
                ? _empty(context)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _totalSoldCard(context, orders),
                      const SizedBox(height: 12),
                      Expanded(
                        child: ListView.separated(
                          padding: const EdgeInsets.only(bottom: 8),
                          itemCount: orders.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 12),
                          itemBuilder: (c, i) => _OrderCard(order: orders[i]),
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.error,
                            side: BorderSide(
                                color:
                                    AppColors.error.withValues(alpha: 0.5)),
                          ),
                          onPressed: () => _confirmDeleteAll(context),
                          icon: const Icon(Icons.delete_outline),
                          label: Text(context.tr('Eliminar todas')),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _totalSoldCard(BuildContext context, List<OrderRecord> orders) {
    final paid = orders.where((o) => o.isPaid);
    final soldSats = paid.fold<int>(0, (s, o) => s + o.amountSats);
    final soldCount = paid.length;
    final ars = pricing.satsToFiat(soldSats, Currency.ars);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          // Left: the sales count.
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$soldCount',
                  style: const TextStyle(
                      fontSize: 24, fontWeight: FontWeight.w800)),
              Text(context.tr(soldCount == 1 ? 'venta' : 'ventas'),
                  style: const TextStyle(color: AppColors.muted, fontSize: 12)),
            ],
          ),
          // Right: the total sold (label + amounts), right-aligned.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(context.tr('Total vendido'),
                    style:
                        const TextStyle(color: AppColors.muted, fontSize: 13)),
                const SizedBox(height: 2),
                Text('${formatToPreference(Currency.sat, soldSats)} sats',
                    style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primary)),
                if (ars != null)
                  Text('≈ ${formatToPreference(Currency.ars, ars)} ARS',
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.receipt_long_outlined,
                size: 48, color: AppColors.muted),
            const SizedBox(height: 12),
            Text(context.tr('Todavía no hay órdenes creadas.'),
                style: const TextStyle(color: AppColors.muted)),
          ],
        ),
      );
}

class _OrderCard extends StatelessWidget {
  final OrderRecord order;
  const _OrderCard({required this.order});

  /// Run the check process (LUD-21 + NIP-57 modal). If it confirms the payment,
  /// the modal marks the order paid; we then run the payment pipeline — print the
  /// ticket exactly like a normal paid order — and surface the printer result.
  Future<void> _recheckAndPrint(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final thankYou = context.tr('Gracias por su pago');
    await showRecheckModal(context, order);
    final paidNow =
        ordersStore.notifier.value.any((o) => o.id == order.id && o.isPaid);
    if (!paidNow) return;
    final result = await printOrderReceipt(
      amountSats: order.amountSats,
      items: order.items,
      thankYouMessage: thankYou,
    );
    messenger.showSnackBar(
      SnackBar(
          content: Text(result.message),
          duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ars = pricing.satsToFiat(order.amountSats, Currency.ars);
    final showRecheck = !order.isPaid && order.canRecheck;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: order.isPaid
              ? AppColors.primary.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.05),
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${formatToPreference(Currency.sat, order.amountSats)} sats',
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w800),
                      ),
                      if (ars != null)
                        Text('≈ ${formatToPreference(Currency.ars, ars)} ARS',
                            style: const TextStyle(
                                color: AppColors.muted, fontSize: 13)),
                    ],
                  ),
                ),
                order.isPaid
                    ? _StatusChip(
                        icon: Icons.check_circle_rounded,
                        color: AppColors.primary,
                        label: context.tr('Acreditado'))
                    : _StatusChip(
                        icon: Icons.hourglass_top_rounded,
                        color: _amber,
                        label: context.tr('Pendiente')),
              ],
            ),
          ),
          if (order.summary.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.shopping_bag_outlined,
                      size: 14, color: AppColors.muted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(order.summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            ),
          // Plain separator line (a Divider widget failed to rasterize here
          // under the web CanvasKit renderer).
          Container(
            height: 1,
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            color: Colors.white.withValues(alpha: 0.06),
          ),
          // Prominent re-check action — the whole point of a pending order.
          // Full-width filled button (the button shape that paints reliably).
          if (showRecheck)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 2),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.onDark,
                    minimumSize: const Size.fromHeight(46),
                  ),
                  onPressed: () => _recheckAndPrint(context),
                  icon: const Icon(Icons.price_check_rounded, size: 20),
                  label: Text(context.tr('Checkear')),
                ),
              ),
            ),
          // Meta row: tap-to-copy id + date.
          Padding(
            padding: EdgeInsets.fromLTRB(16, showRecheck ? 4 : 10, 16, 12),
            child: Row(
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: order.id));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content: Text(context.tr('ID copiado')),
                          duration: const Duration(seconds: 1)),
                    );
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.copy_rounded,
                          size: 14, color: AppColors.muted),
                      const SizedBox(width: 4),
                      Text(
                        order.id.length > 12
                            ? '${order.id.substring(0, 12)}…'
                            : order.id,
                        style: const TextStyle(
                            color: AppColors.muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Text(_df.format(order.createdAtDate),
                    style:
                        const TextStyle(color: AppColors.muted, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A small status chip with an icon + label.
class _StatusChip extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  const _StatusChip(
      {required this.icon, required this.color, required this.label});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    color: color, fontSize: 12, fontWeight: FontWeight.w700)),
          ],
        ),
      );
}
