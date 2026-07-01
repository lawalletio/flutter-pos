import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/mock/mock_data.dart';
import '../../data/pricing/pricing_service.dart';
import '../../domain/config/currencies.dart';
import '../../domain/config/formatter.dart';

const Color _amber = Color(0xFFE0A82E);

/// Orders — session payment history. Payment / publish / zap state are shown as
/// icons (Pendiente, Acreditado, Publicado) rather than text badges.
class OrdersScreen extends StatelessWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    pricing.ensureLoaded();
    final df = DateFormat('dd/MM · HH:mm');
    final orders = kMockOrders;
    final paidCount = orders.where((o) => o.isPaid).length;

    return Scaffold(
      appBar: const PosAppBar(title: 'Órdenes'),
      body: ValueListenableBuilder<Rates?>(
        valueListenable: pricing.notifier,
        builder: (context, _, __) => PosBody(
          child: orders.isEmpty
              ? _empty()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(2, 4, 2, 12),
                      child: Text(
                        '${orders.length} órdenes · $paidCount acreditadas',
                        style: const TextStyle(
                            color: AppColors.muted, fontSize: 13),
                      ),
                    ),
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.only(bottom: 16),
                        itemCount: orders.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (c, i) => _OrderCard(order: orders[i], df: df),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _empty() => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.receipt_long_outlined, size: 48, color: AppColors.muted),
            SizedBox(height: 12),
            Text('Todavía no hay órdenes creadas.',
                style: TextStyle(color: AppColors.muted)),
          ],
        ),
      );
}

class _OrderCard extends StatelessWidget {
  final MockOrder order;
  final DateFormat df;
  const _OrderCard({required this.order, required this.df});

  @override
  Widget build(BuildContext context) {
    final ars = pricing.satsToFiat(order.amountSats, Currency.ars);
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
                // Status icons: payment, publish, zap.
                Row(
                  children: [
                    order.isPaid
                        ? const _StatusIcon(
                            icon: Icons.check_circle_rounded,
                            color: AppColors.primary,
                            tooltip: 'Acreditado')
                        : const _StatusIcon(
                            icon: Icons.hourglass_top_rounded,
                            color: _amber,
                            tooltip: 'Pendiente'),
                    const SizedBox(width: 6),
                    _StatusIcon(
                      icon: order.publishStatus == 'Fallida'
                          ? Icons.error_rounded
                          : Icons.podcasts_rounded,
                      color: order.publishStatus == 'Publicada'
                          ? AppColors.primary
                          : order.publishStatus == 'Fallida'
                              ? AppColors.error
                              : AppColors.muted,
                      tooltip:
                          'Publicado · ${order.publishRelays} relays',
                      count: order.publishRelays,
                    ),
                    const SizedBox(width: 6),
                    _StatusIcon(
                      icon: Icons.bolt_rounded,
                      color: order.zapStatus == 'Confirmado'
                          ? _amber
                          : AppColors.muted,
                      tooltip: 'Zap ${order.zapStatus.toLowerCase()} · '
                          '${order.zapRelays} relays',
                      count: order.zapRelays,
                    ),
                  ],
                ),
              ],
            ),
          ),
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
          Divider(
              height: 20,
              thickness: 1,
              indent: 16,
              endIndent: 16,
              color: Colors.white.withValues(alpha: 0.06)),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 12, 8),
            child: Row(
              children: [
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.muted,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: order.id));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('ID copiado'),
                          duration: Duration(seconds: 1)),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded, size: 14),
                  label: Text(
                    order.id.length > 12
                        ? '${order.id.substring(0, 12)}…'
                        : order.id,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
                const Spacer(),
                Text(df.format(order.createdAt),
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

/// A small icon status badge with a tooltip and an optional relay count.
class _StatusIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final int? count;
  const _StatusIcon({
    required this.icon,
    required this.color,
    required this.tooltip,
    this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: count != null ? 8 : 6, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            if (count != null) ...[
              const SizedBox(width: 3),
              Text('$count',
                  style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w700)),
            ],
          ],
        ),
      ),
    );
  }
}
