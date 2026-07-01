import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/mock/mock_data.dart';
import '../../domain/config/settings_state.dart';
import '../../domain/order/order_reset.dart';

/// Destination hub — shows the single venue menu that matches the merchant
/// address (like the webapp) plus the always-available POS modes.
class HubScreen extends StatelessWidget {
  final String address;
  const HubScreen({super.key, this.address = 'barra@lacrypta.ar'});

  @override
  Widget build(BuildContext context) {
    final venue = venueForAddress(address);

    return Scaffold(
      appBar: const PosAppBar(showBack: false),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton.icon(
                onPressed: () {
                  resetOrder();
                  context.go('/');
                },
                icon:
                    const Icon(Icons.logout, size: 14, color: AppColors.muted),
                label: const Text('Cerrar sesión',
                    style: TextStyle(color: AppColors.muted, fontSize: 12)),
              ),
            ],
          ),
        ),
      ),
      body: PosBody(
        child: ListView(
          children: [
            Row(
              children: [
                const Icon(Icons.storefront, color: AppColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(address,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Only the menu matching this address (or none for a non-venue address).
            if (venue != null) ...[
              const _SectionLabel('Menú'),
              PosCard(
                icon: Icons.restaurant_menu,
                label: venue.title,
                onTap: () => context.push('/cart/${venue.menu}'),
              ),
              const SizedBox(height: 12),
            ],
            const _SectionLabel('Modos'),
            PosCard(
              icon: Icons.calculate_outlined,
              label: 'Caja registradora',
              sublabel: 'Cobrar un monto manual',
              onTap: () => context.push('/paydesk'),
            ),
            const SizedBox(height: 10),
            PosCard(
              icon: Icons.receipt_long_outlined,
              label: 'Órdenes',
              sublabel: 'Historial de la sesión',
              onTap: () => context.push('/orders'),
            ),
            // 'Cuentas abiertas' is gated behind the Tab setting (default off),
            // like the webapp's `tabEnabled`.
            ValueListenableBuilder<SettingsState>(
              valueListenable: appSettings,
              builder: (context, s, _) => s.tabEnabled
                  ? Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: PosCard(
                        icon: Icons.account_balance_wallet_outlined,
                        label: 'Cuentas abiertas',
                        sublabel: 'Tabs de clientes',
                        color: const Color(0xFF2C2438),
                        onTap: () => context.push('/tab'),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10, top: 4),
        child: Text(text.toUpperCase(),
            style: const TextStyle(
                color: AppColors.muted,
                fontSize: 12,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600)),
      );
}
