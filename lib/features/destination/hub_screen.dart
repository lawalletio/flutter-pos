import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/mock/mock_data.dart';

/// Destination hub — venue menus + POS modes.
class HubScreen extends StatelessWidget {
  const HubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const PosAppBar(showBack: false),
      body: PosBody(
        child: ListView(
          children: [
            Row(
              children: [
                const Icon(Icons.storefront, color: AppColors.primary),
                const SizedBox(width: 8),
                const Text('barra@lacrypta.ar',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 18, color: AppColors.muted),
                  onPressed: () => context.go('/'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const _SectionLabel('Menús'),
            ...kVenues.map((v) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: PosCard(
                    icon: Icons.restaurant_menu,
                    label: v.title,
                    onTap: () => context.push('/cart/${v.menu}'),
                  ),
                )),
            const SizedBox(height: 12),
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
            const SizedBox(height: 10),
            PosCard(
              icon: Icons.account_balance_wallet_outlined,
              label: 'Cuentas abiertas',
              sublabel: 'Tabs de clientes',
              color: const Color(0xFF2C2438),
              onTap: () => context.push('/tab'),
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
