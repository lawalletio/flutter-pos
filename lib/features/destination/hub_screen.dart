import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/mock/mock_data.dart';
import '../../data/nostr/profile_service.dart';
import '../../domain/config/address_history.dart';
import '../../domain/config/session.dart';
import '../../domain/config/settings_state.dart';
import '../../domain/order/order_reset.dart';

/// Destination hub — shows the single venue menu that matches the merchant
/// address plus the POS modes. The address header is a full-width dropdown
/// listing the history of used Lightning Addresses (persisted), each removable
/// via an X, plus an "enter another address" action; opening it blurs the hub.
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
  final GlobalKey _toggleKey = GlobalKey();
  OverlayEntry? _dropdownEntry;
  String? _avatar; // resolved Nostr profile picture for the current address

  bool get _isOpen => _dropdownEntry != null;

  @override
  void initState() {
    super.initState();
    _init();
    _resolveAvatar();
  }

  Future<void> _resolveAvatar() async {
    final url = await nostrProfile.avatarFor(widget.address);
    if (mounted && url != null) setState(() => _avatar = url);
  }

  /// Avatar (if resolved) to the left of the address, else the storefront icon.
  Widget _leading() {
    if (_avatar == null) {
      return const Icon(Icons.storefront, color: AppColors.primary);
    }
    return ClipOval(
      child: Image.network(
        _avatar!,
        width: 26,
        height: 26,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            const Icon(Icons.storefront, color: AppColors.primary),
      ),
    );
  }

  @override
  void dispose() {
    _dropdownEntry?.remove();
    _dropdownEntry = null;
    super.dispose();
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
        WidgetsBinding.instance.addPostFrameCallback((_) => _openDropdown());
      }
    }
  }

  void _toggleDropdown() => _isOpen ? _closeDropdown() : _openDropdown();

  void _closeDropdown() {
    if (!_isOpen) return;
    _dropdownEntry?.remove();
    _dropdownEntry = null;
    if (mounted) setState(() {}); // flip the toggle arrow
  }

  void _openDropdown() {
    if (_isOpen) return;
    final box = _toggleKey.currentContext?.findRenderObject() as RenderBox?;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlayBox == null) return;
    final size = box.size;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlayBox);

    _dropdownEntry = OverlayEntry(
      builder: (ctx) => Stack(
        children: [
          // Blur backdrop — tap anywhere outside to dismiss.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closeDropdown,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: Container(color: Colors.black.withValues(alpha: 0.28)),
              ),
            ),
          ),
          // Dropdown card — full width, aligned to the toggle.
          Positioned(
            left: topLeft.dx,
            top: topLeft.dy + size.height + 6,
            width: size.width,
            child: _dropdownCard(),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_dropdownEntry!);
    setState(() {}); // flip the toggle arrow
  }

  Widget _dropdownCard() {
    return Material(
      color: AppColors.surface,
      elevation: 10,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: ValueListenableBuilder<List<String>>(
        valueListenable: addressHistory.notifier,
        builder: (context, history, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 6),
            for (final addr in history) _addressItem(addr),
            if (history.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(context.tr('Sin historial'),
                    style:
                        const TextStyle(color: AppColors.muted, fontSize: 16)),
              ),
            const Divider(height: 1, indent: 14, endIndent: 14),
            _addNewAddressItem(),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  void _select(String addr) {
    _closeDropdown();
    merchantAddress.value = addr;
    context.go('/hub?address=${Uri.encodeComponent(addr)}');
  }

  @override
  Widget build(BuildContext context) {
    final venue = venueForAddress(widget.address);

    return Scaffold(
      appBar: const PosAppBar(showBack: false),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.only(bottom: 10, top: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: () {
                resetOrder();
                context.go('/');
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.error,
                side: BorderSide(color: AppColors.error.withValues(alpha: 0.4)),
                minimumSize: const Size(0, 40),
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                textStyle:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              icon: const Icon(Icons.logout, size: 18),
              label: Text(context.tr('Cerrar sesión')),
            ),
          ],
        ),
      ),
      body: PosBody(
        child: ListView(
          children: [
            _addressToggle(),
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
              label: context.tr('Caja registradora'),
              sublabel: context.tr('Cobrar un monto manual'),
              onTap: () => context.push('/paydesk'),
            ),
            const SizedBox(height: 10),
            PosCard(
              icon: Icons.receipt_long_outlined,
              label: context.tr('Órdenes'),
              sublabel: context.tr('Historial de la sesión'),
              onTap: () => context.push('/orders'),
            ),
            ValueListenableBuilder<SettingsState>(
              valueListenable: appSettings,
              builder: (context, s, _) => s.tabEnabled
                  ? Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: PosCard(
                        icon: Icons.account_balance_wallet_outlined,
                        label: context.tr('Cuentas abiertas'),
                        sublabel: context.tr('Tabs de clientes'),
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

  /// The clickable, full-width toggle that opens the address dropdown.
  Widget _addressToggle() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: _toggleKey,
        borderRadius: BorderRadius.circular(10),
        onTap: _toggleDropdown,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Row(
            children: [
              _leading(),
              const SizedBox(width: 8),
              Expanded(
                child: Text(widget.address,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              Icon(_isOpen ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                  color: AppColors.muted),
            ],
          ),
        ),
      ),
    );
  }

  Widget _addressItem(String addr) {
    final isCurrent = addr == widget.address;
    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: () => _select(addr),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              child: Row(
                children: [
                  if (isCurrent)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child:
                          Icon(Icons.check, size: 18, color: AppColors.primary),
                    ),
                  Expanded(
                    child: Text(addr,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 16,
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
          tooltip: context.tr('Eliminar del historial'),
          icon: const Icon(Icons.close, size: 18, color: AppColors.muted),
          onPressed: () => addressHistory.remove(addr),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  /// Bottom entry of the address dropdown: enter a different Lightning Address.
  /// Logs out (clears the current order) and returns to the Home entry screen.
  Widget _addNewAddressItem() {
    return InkWell(
      onTap: () {
        _closeDropdown();
        resetOrder();
        context.go('/');
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        child: Row(
          children: [
            const Icon(Icons.add_circle_outline,
                size: 20, color: AppColors.primary),
            const SizedBox(width: 10),
            Text(context.tr('Ingresar otra dirección'),
                style: const TextStyle(
                    fontSize: 16,
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600)),
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
        child: Text(context.tr(text.toUpperCase()),
            style: const TextStyle(
                color: AppColors.muted,
                fontSize: 12,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600)),
      );
}
