import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/mock/mock_data.dart';
import '../../domain/config/currencies.dart';
import '../../domain/config/formatter.dart';

/// Tab — open customer accounts (mock data). Tap a tab to charge it.
class TabScreen extends StatelessWidget {
  const TabScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const PosAppBar(title: 'Cuentas abiertas'),
      body: PosBody(
        child: kMockTabs.isEmpty
            ? const Center(child: Text('No hay cuentas abiertas.'))
            : ListView.separated(
                itemCount: kMockTabs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (c, i) {
                  final t = kMockTabs[i];
                  return Material(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => context.push('/payment?sats=${t.amountSats}'),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(t.name,
                                      style: const TextStyle(
                                          fontSize: 17,
                                          fontWeight: FontWeight.w700)),
                                  const SizedBox(height: 4),
                                  Text(t.summary,
                                      style: const TextStyle(
                                          color: AppColors.muted, fontSize: 13)),
                                ],
                              ),
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text('${formatToPreference(Currency.sat, t.amountSats)} sats',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700)),
                                Text('${formatToPreference(Currency.ars, t.amountSats * 0.7)} ARS',
                                    style: const TextStyle(
                                        color: AppColors.muted, fontSize: 12)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
