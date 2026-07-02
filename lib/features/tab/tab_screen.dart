import 'package:flutter/material.dart';

import '../../core/checkout.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/mock/mock_data.dart';
import '../../data/pricing/pricing_service.dart';
import '../../domain/config/currencies.dart';
import '../../domain/config/formatter.dart';

/// Tab — open customer accounts (mock). Tap a tab to charge it (routes through
/// tip when enabled); "Borrar todo" clears all with a confirmation.
class TabScreen extends StatefulWidget {
  const TabScreen({super.key});
  @override
  State<TabScreen> createState() => _TabScreenState();
}

class _TabScreenState extends State<TabScreen> {
  late final List<MockTab> _tabs = List.of(kMockTabs);

  @override
  void initState() {
    super.initState();
    pricing.ensureLoaded();
    pricing.notifier.addListener(_onRates);
  }

  @override
  void dispose() {
    pricing.notifier.removeListener(_onRates);
    super.dispose();
  }

  void _onRates() {
    if (mounted) setState(() {});
  }

  void _clearAll() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.background,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(context.tr('¿Borrar todas las cuentas?'),
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
                context.tr('Esta acción no se puede deshacer.'),
                style: const TextStyle(color: AppColors.muted)),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: Text(context.tr('Cancelar')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: AppColors.error),
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      setState(_tabs.clear);
                    },
                    child: Text(context.tr('Borrar todo')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PosAppBar(title: context.tr('Cuentas abiertas')),
      body: PosBody(
        child: _tabs.isEmpty
            ? Center(child: Text(context.tr('No hay cuentas abiertas.')))
            : Column(
                children: [
                  Expanded(
                    child: ListView.separated(
                      itemCount: _tabs.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (c, i) {
                        final t = _tabs[i];
                        return Material(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => goCheckout(context,
                                sats: t.amountSats, back: '/tab'),
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(t.name,
                                            style: const TextStyle(
                                                fontSize: 17,
                                                fontWeight: FontWeight.w700)),
                                        const SizedBox(height: 4),
                                        Text(t.summary,
                                            style: const TextStyle(
                                                color: AppColors.muted,
                                                fontSize: 13)),
                                      ],
                                    ),
                                  ),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                          '${formatToPreference(Currency.sat, t.amountSats)} sats',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700)),
                                      Text(
                                          '${formatToPreference(Currency.ars, pricing.satsToFiat(t.amountSats, Currency.ars) ?? 0)} ARS',
                                          style: const TextStyle(
                                              color: AppColors.muted,
                                              fontSize: 12)),
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
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.error),
                      onPressed: _clearAll,
                      icon: const Icon(Icons.delete_outline),
                      label: Text(context.tr('Borrar todo')),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
