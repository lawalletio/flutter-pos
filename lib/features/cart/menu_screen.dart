import 'package:flutter/material.dart';

import '../../core/checkout.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/mock/mock_data.dart';
import '../../data/pricing/pricing_service.dart';
import '../../domain/config/currencies.dart';
import '../../domain/config/formatter.dart';
import '../../domain/order/product.dart';

/// Menu/cart — product catalog grouped by category, add/remove, clear, and a
/// "Ver carrito" → "Resumen de compra" review sheet before checkout.
class MenuScreen extends StatefulWidget {
  final String menu;
  final bool demo; // preview affordance: pre-fill the cart to show highlighting
  const MenuScreen({super.key, required this.menu, this.demo = false});
  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  List<Product> _products = [];
  List<({int id, String name})> _categories = [];
  final Map<int, CartLine> _cart = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
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

  Future<void> _load() async {
    final cats = await loadCategories();
    final prods = await loadMenu(widget.menu);
    if (!mounted) return;
    if (widget.demo && prods.length >= 2) {
      _cart[prods[0].id] = CartLine(prods[0], 3);
      _cart[prods[1].id] = CartLine(prods[1], 1);
    }
    setState(() {
      _categories = cats;
      _products = prods;
      _loading = false;
    });
  }

  int get _itemCount => _cart.values.fold(0, (s, l) => s + l.qty);
  num get _totalArs => _cart.values.fold<num>(0, (s, l) => s + l.subtotal);
  int get _totalSats => pricing.fiatToSats(_totalArs, Currency.ars) ?? 0;

  void _add(Product p) => setState(() {
        _cart.update(p.id, (l) {
          l.qty++;
          return l;
        }, ifAbsent: () => CartLine(p));
      });
  void _remove(Product p) => setState(() {
        final l = _cart[p.id];
        if (l == null) return;
        if (l.qty <= 1) {
          _cart.remove(p.id);
        } else {
          l.qty--;
        }
      });
  void _clear() => setState(_cart.clear);

  @override
  Widget build(BuildContext context) {
    // Group products by category, rendered in canonical category order.
    final grouped = <int, List<Product>>{};
    for (final p in _products) {
      grouped.putIfAbsent(p.categoryId, () => []).add(p);
    }
    final orderedCatIds = [
      ..._categories.map((c) => c.id).where(grouped.containsKey),
      ...grouped.keys.where((id) => !_categories.any((c) => c.id == id)),
    ];
    final catName = {for (final c in _categories) c.id: c.name};

    return Scaffold(
      appBar: PosAppBar(
          title: widget.menu[0].toUpperCase() + widget.menu.substring(1)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : PosBody(
              padding: EdgeInsets.zero,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
                children: [
                  for (final catId in orderedCatIds) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(0, 14, 0, 8),
                      child: Text(
                        (catName[catId] ?? 'Otros').toUpperCase(),
                        style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 12,
                            letterSpacing: 1.1,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                    ...grouped[catId]!.map(_productTile),
                  ],
                ],
              ),
            ),
      bottomNavigationBar: _itemCount == 0
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    // Clear cart (trash + count).
                    Material(
                      color: AppColors.error.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: _clear,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 16),
                          child: Row(children: [
                            const Icon(Icons.delete_outline,
                                color: AppColors.error, size: 20),
                            const SizedBox(width: 6),
                            Text('$_itemCount',
                                style: const TextStyle(
                                    color: AppColors.error,
                                    fontWeight: FontWeight.w700)),
                          ]),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _openCartSheet,
                        child: const Text('Ver carrito'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  void _openCartSheet() {
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
            const Text('Resumen de compra',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            ..._cart.values.map((l) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l.product.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            Text('${l.qty} ${l.qty == 1 ? 'unidad' : 'unidades'}',
                                style: const TextStyle(
                                    color: AppColors.muted, fontSize: 12)),
                          ],
                        ),
                      ),
                      Text('ARS ${formatToPreference(Currency.ars, l.subtotal)}',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                    ],
                  ),
                )),
            const Divider(height: 24),
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                goCheckout(context,
                    sats: _totalSats, back: '/cart/${widget.menu}');
              },
              child: Text(
                  'Cobrar ${formatToPreference(Currency.sat, _totalSats)} sats'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _productTile(Product p) {
    final line = _cart[p.id];
    final qty = line?.qty ?? 0;
    // Highlight items in the cart with more background; the more units, the
    // stronger the emphasis.
    final inCart = qty >= 1;
    final many = qty > 1;
    final bg = many
        ? AppColors.primary.withValues(alpha: 0.20)
        : inCart
            ? AppColors.primary.withValues(alpha: 0.10)
            : AppColors.surface;
    final border = many
        ? Border.all(color: AppColors.primary.withValues(alpha: 0.6), width: 1.5)
        : inCart
            ? Border.all(color: AppColors.primary.withValues(alpha: 0.3))
            : null;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: border,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.name,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
                Text(
                    '${p.priceCurrency} ${formatToPreference(Currency.ars, p.priceValue)}',
                    style:
                        const TextStyle(color: AppColors.muted, fontSize: 13)),
              ],
            ),
          ),
          if (qty > 0) ...[
            _RoundBtn(icon: Icons.remove, onTap: () => _remove(p)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text('$qty',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: inCart ? AppColors.primary : null)),
            ),
          ],
          _RoundBtn(icon: Icons.add, onTap: () => _add(p)),
        ],
      ),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _RoundBtn({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.background,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 20, color: AppColors.primary),
        ),
      ),
    );
  }
}
