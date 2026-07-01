import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/mock/mock_data.dart';
import '../../domain/config/currencies.dart';
import '../../domain/config/formatter.dart';
import '../../domain/order/product.dart';

/// Menu/cart — product catalog grouped by category, add/remove, cart summary.
class MenuScreen extends StatefulWidget {
  final String menu;
  const MenuScreen({super.key, required this.menu});
  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  static const _arsPerBtc = 70000000.0;

  List<Product> _products = [];
  Map<int, String> _categories = {};
  final Map<int, CartLine> _cart = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cats = await loadCategories();
    final prods = await loadMenu(widget.menu);
    if (!mounted) return;
    setState(() {
      _categories = cats;
      _products = prods;
      _loading = false;
    });
  }

  int get _itemCount => _cart.values.fold(0, (s, l) => s + l.qty);
  num get _totalArs => _cart.values.fold<num>(0, (s, l) => s + l.subtotal);
  int get _totalSats => (_totalArs / _arsPerBtc * 100000000).round();

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

  @override
  Widget build(BuildContext context) {
    final grouped = <int, List<Product>>{};
    for (final p in _products) {
      grouped.putIfAbsent(p.categoryId, () => []).add(p);
    }

    return Scaffold(
      appBar: PosAppBar(title: widget.menu[0].toUpperCase() + widget.menu.substring(1)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : PosBody(
              padding: EdgeInsets.zero,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
                children: [
                  for (final entry in grouped.entries) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(0, 14, 0, 8),
                      child: Text(
                        (_categories[entry.key] ?? 'Otros').toUpperCase(),
                        style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 12,
                            letterSpacing: 1.1,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                    ...entry.value.map(_productTile),
                  ],
                ],
              ),
            ),
      bottomNavigationBar: _itemCount == 0
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton(
                  onPressed: () => context.push('/payment?sats=$_totalSats'),
                  child: Text(
                      'Cobrar · ${formatToPreference(Currency.ars, _totalArs)} ARS · $_itemCount ítems'),
                ),
              ),
            ),
    );
  }

  Widget _productTile(Product p) {
    final line = _cart[p.id];
    final qty = line?.qty ?? 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
          color: AppColors.surface, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.name,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
                Text('${p.priceCurrency} ${formatToPreference(Currency.ars, p.priceValue)}',
                    style: const TextStyle(color: AppColors.muted, fontSize: 13)),
              ],
            ),
          ),
          if (qty > 0) ...[
            _RoundBtn(icon: Icons.remove, onTap: () => _remove(p)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text('$qty',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
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
