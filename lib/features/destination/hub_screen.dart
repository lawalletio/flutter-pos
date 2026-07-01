import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/mock/mock_data.dart';
import '../../domain/config/address_history.dart';
import '../../domain/config/session.dart';
import '../../domain/config/settings_state.dart';
import '../../domain/order/order_reset.dart';

/// Destination hub — shows the single venue menu that matches the merchant
/// address plus the POS modes. The address header is a dropdown listing the
/// history of used Lightning Addresses (persisted), each removable via an X.
class HubScreen extends StatefulWidget {
  final String address;
  final bool openMenu; // preview affordance: auto-open the address dropdown
  const HubScreen({
    super.key,
    this.address = 'barra@lacrypta.ar',
    this.openMenu = false,
  });

  @override
  State<HubScreen> createState() => _HubScreenState();
}

class _HubScreenState extends State<HubScreen> {
  final MenuController _menu = MenuController();

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await addressHistory.load();
    await addressHistory.add(widget.address); // record the active address
    if (widget.openMenu) {
      // Seed a couple of extra addresses so the dropdown has a list to show.
      await addressHistory.add('merch@lacrypta.ar');
      await addressHistory.add('comida@lacrypta.ar');
      await addressHistory.add(widget.address);
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _menu.open());
      }
    }
  }

  void _select(String addr) {
    _menu.close();
    merchantAddress.value = addr;
    context.go('/hub?address=${Uri.encodeComponent(addr)}');
  }

  @override
  Widget build(BuildContext context) {
    final venue = venueForAddress(widget.address);

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
            _addressDropdown(),
            const SizedBox(height: 8),
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

  Widget _addressDropdown() {
    return ValueListenableBuilder<List<String>>(
      valueListenable: addressHistory.notifier,
      builder: (context, history, _) {
        return MenuAnchor(
          controller: _menu,
          alignmentOffset: const Offset(0, 4),
          style: MenuStyle(
            backgroundColor:
                const WidgetStatePropertyAll(AppColors.surface),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(vertical: 6)),
          ),
          menuChildren: [
            for (final addr in history) _addressItem(addr),
            if (history.isEmpty)
              const Padding(
                padding: EdgeInsets.all(14),
                child: Text('Sin historial',
                    style: TextStyle(color: AppColors.muted)),
              ),
          ],
          builder: (context, controller, child) => InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () =>
                controller.isOpen ? controller.close() : controller.open(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Row(
                children: [
                  const Icon(Icons.storefront, color: AppColors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(widget.address,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  const Icon(Icons.arrow_drop_down, color: AppColors.muted),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _addressItem(String addr) {
    final isCurrent = addr == widget.address;
    return SizedBox(
      width: 300,
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () => _select(addr),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                child: Row(
                  children: [
                    if (isCurrent)
                      const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: Icon(Icons.check,
                            size: 16, color: AppColors.primary),
                      ),
                    Expanded(
                      child: Text(addr,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight: isCurrent
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                              color: isCurrent ? AppColors.primary : null)),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Eliminar del historial',
            icon: const Icon(Icons.close, size: 16, color: AppColors.muted),
            onPressed: () => addressHistory.remove(addr),
          ),
        ],
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
