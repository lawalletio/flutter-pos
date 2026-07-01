import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/mock/mock_data.dart';
import '../../domain/config/currencies.dart';
import '../../domain/config/formatter.dart';

/// Orders — session payment history (mock data).
class OrdersScreen extends StatelessWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('MMM d, HH:mm');
    return Scaffold(
      appBar: const PosAppBar(title: 'Órdenes'),
      body: PosBody(
        child: kMockOrders.isEmpty
            ? const Center(child: Text('Todavía no hay órdenes creadas.'))
            : ListView.separated(
                itemCount: kMockOrders.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (c, i) {
                  final o = kMockOrders[i];
                  return Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(12)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(o.id,
                                  style: const TextStyle(
                                      fontFamily: 'monospace',
                                      color: AppColors.muted)),
                            ),
                            Text('${formatToPreference(Currency.sat, o.amountSats)} sats',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(o.summary, style: const TextStyle(fontSize: 13)),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            _StatusChip(
                              label: o.isPaid ? 'Acreditado' : 'Pendiente',
                              color: o.isPaid ? AppColors.primary : AppColors.muted,
                            ),
                            const Spacer(),
                            Text(df.format(o.createdAt),
                                style: const TextStyle(
                                    color: AppColors.muted, fontSize: 12)),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusChip({required this.label, required this.color});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20)),
        child: Text(label,
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.w600)),
      );
}
