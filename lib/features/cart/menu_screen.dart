import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/checkout.dart';
import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/mock/mock_data.dart';
import '../../data/nostr/catalog_service.dart';
import '../../data/pricing/pricing_service.dart';
import '../../domain/config/currencies.dart';
import '../../domain/config/formatter.dart';
import '../../domain/config/session.dart';
import '../../domain/order/current_order.dart';
import '../../domain/order/order_reset.dart';
import '../../domain/order/product.dart';

/// Where the products on screen came from — drives the banners and the empty
/// states, which are the only signal an operator gets that they may be looking
/// at prices that are not live.
enum _Source { nostr, cache, bundled, empty, offline }

/// Menu/cart — product catalog grouped by category, add/remove, clear, and a
/// "Ver carrito" → "Resumen de compra" review sheet before checkout.
///
/// The catalog comes from the merchant's own NIP-99 events on nostr, resolved
/// from their Lightning Address. The bundled `assets/menus/*.json` are only a
/// fallback for addresses with no nostr identity at all; see [_load].
class MenuScreen extends StatefulWidget {
  /// Bundled fallback menu name, when the address maps to one of the hardcoded
  /// venues. Null for a merchant that only exists on nostr.
  final String? menu;
  final bool demo; // preview affordance: pre-fill the cart to show highlighting
  const MenuScreen({super.key, this.menu, this.demo = false});
  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  List<Product> _products = [];
  List<({int id, String name})> _categories = [];
  final Map<int, CartLine> _cart = {};
  bool _loading = true;
  _Source _source = _Source.nostr;
  int _unsellable = 0;
  DateTime? _fetchedAt;

  /// A catalog that arrived while the cart was non-empty, held until it clears.
  CatalogResult? _pendingRefresh;

  @override
  void initState() {
    super.initState();
    _load();
    pricing.ensureLoaded();
    pricing.notifier.addListener(_onRates);
    orderResetSignal.addListener(_onOrderReset);
    catalog.notifier.addListener(_onCatalog);
    merchantAddress.addListener(_onMerchantChanged);
  }

  @override
  void dispose() {
    pricing.notifier.removeListener(_onRates);
    orderResetSignal.removeListener(_onOrderReset);
    catalog.notifier.removeListener(_onCatalog);
    merchantAddress.removeListener(_onMerchantChanged);
    super.dispose();
  }

  void _onRates() {
    if (mounted) setState(() {});
  }

  // Clear the cart when an order completes (payment or moved to a tab).
  void _onOrderReset() {
    if (!mounted) return;
    setState(_cart.clear);
    _applyPendingRefresh();
  }

  /// go_router keeps this page alive, so the merchant can change underneath it.
  /// Selling merchant A's menu against merchant B's address is a money bug.
  void _onMerchantChanged() {
    if (!mounted) return;
    setState(() {
      _cart.clear();
      _loading = true;
    });
    _load();
  }

  void _onCatalog() {
    final result = catalog.notifier.value;
    if (!mounted || result == null) return;
    if (result.address != merchantAddress.value.trim().toLowerCase()) return;

    // Product ids are list indices, so a refresh renumbers everything and would
    // re-point open cart lines at different products. Hold it until the cart
    // clears — cheaper and safer than reconciling line by line.
    if (_cart.isNotEmpty) {
      _pendingRefresh = result;
      return;
    }
    // Through the full decision, not straight to _adopt: a revalidation that
    // comes back empty must fall to the bundled menu, not blank the screen.
    _adoptAsync(result);
  }

  void _applyPendingRefresh() {
    final pending = _pendingRefresh;
    if (pending == null) return;
    _pendingRefresh = null;
    _adoptAsync(pending);
  }

  Future<void> _load() async {
    final address = merchantAddress.value;
    final key = address.trim().toLowerCase();

    // Paint what we ALREADY hold before awaiting anything. `ensureLoaded` only
    // returns immediately while its TTL is warm; the moment a read comes back
    // incomplete the service drops that mark, so the next open would sit on a
    // spinner through a full relay round trip — with a perfectly good catalog
    // in memory the whole time. Whatever we have goes on screen now and the
    // refresh lands through the notifier.
    final existing = catalog.notifier.value;
    if (existing != null && existing.address == key) {
      await _adoptAsync(existing);
    }

    await catalog.ensureLoaded(address);
    if (!mounted) return;

    final result = catalog.notifier.value;
    if (result == null || result.address != key) {
      await _loadBundled();
      return;
    }
    // The listener already adopts fresh results; only step in if nothing has.
    if (_cart.isEmpty) await _adoptAsync(result);

    // The menu is on screen; now check the relays for changes. A merchant can
    // reprice or delist between two customers, so opening the menu is exactly
    // the moment to re-ask. Deliberately not awaited — the answer arrives via
    // the notifier, and the listener holds it while a cart is open.
    catalog.revalidate(address).ignore();
  }

  Future<void> _adoptAsync(CatalogResult result) async {
    // 1. A live catalog wins. So does a cached one during an outage — the
    //    service hands those over already populated, flagged `fromCache`, and
    //    the banner dates them.
    if (result.hasProducts) {
      _adopt(result);
      return;
    }

    // 2. The relays answered and this merchant publishes nothing at all (or has
    //    no nostr identity in the first place, like cafe/bitnaria/test). Nostr
    //    has nothing to be stale about, so the bundled menu is the whole truth
    //    for them — and it is exactly what shipped before this change.
    if (!result.unreachable && result.unsellable == 0) {
      await _loadBundled();
      return;
    }

    // 3. Either no relay answered — we learned nothing, and bundled prices are
    //    a build artifact months old, so quietly swapping them in during an
    //    outage would undercharge every sale with no signal — or the merchant
    //    publishes only items this till cannot charge. Paydesk is the safe
    //    manual path out of both.
    if (!mounted) return;
    setState(() {
      _products = const [];
      _categories = const [];
      _unsellable = result.unsellable;
      _fetchedAt = result.fetchedAt;
      _source = result.unreachable ? _Source.offline : _Source.empty;
      _loading = false;
    });
  }

  void _adopt(CatalogResult result) {
    if (!mounted) return;
    if (widget.demo && result.products.length >= 2) {
      _cart[result.products[0].id] = CartLine(result.products[0], 3);
      _cart[result.products[1].id] = CartLine(result.products[1], 1);
    }
    setState(() {
      _products = result.products;
      _categories = result.categories;
      _unsellable = result.unsellable;
      _fetchedAt = result.fetchedAt;
      _source = result.fromCache ? _Source.cache : _Source.nostr;
      _loading = false;
    });
  }

  Future<void> _loadBundled() async {
    final name = widget.menu;
    if (name == null) {
      if (!mounted) return;
      setState(() {
        _products = const [];
        _categories = const [];
        _source = _Source.empty;
        _loading = false;
      });
      return;
    }
    final cats = await loadCategories();
    final prods = await loadMenu(name);
    if (!mounted) return;
    if (widget.demo && prods.length >= 2) {
      _cart[prods[0].id] = CartLine(prods[0], 3);
      _cart[prods[1].id] = CartLine(prods[1], 1);
    }
    setState(() {
      _categories = cats;
      _products = prods;
      _unsellable = 0;
      _fetchedAt = null;
      _source = _Source.bundled;
      _loading = false;
    });
  }

  int get _itemCount => _cart.values.fold(0, (s, l) => s + l.qty);

  /// Null while any currency in the cart has no rate loaded — the charge must
  /// be blocked, not guessed at.
  int? get _totalSats => cartTotalSats(_cart.values, pricing.fiatToSats);

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

    final menu = widget.menu;
    return Scaffold(
      appBar: PosAppBar(
        title: menu == null
            ? context.tr('Menú')
            : menu[0].toUpperCase() + menu.substring(1),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _products.isEmpty
              ? _emptyState()
              : PosBody(
                  padding: EdgeInsets.zero,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
                    children: [
                      ..._notices(),
                      for (final catId in orderedCatIds) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(0, 14, 0, 8),
                          child: Text(
                            (catName[catId] ?? context.tr('Otros'))
                                .toUpperCase(),
                            style: const TextStyle(
                                color: AppColors.muted,
                                fontSize: 14,
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
                        child: Text(context.tr('Ver carrito')),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  /// Where "Volver" goes from checkout — mirrors the route that opened us.
  String get _backRoute =>
      widget.menu == null ? '/cart' : '/cart?menu=${widget.menu}';

  /// Bare magnitude ("5 min"), so the surrounding label reads correctly in both
  /// languages without a word-order-dependent "hace"/"ago" to place.
  String _ago(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return context.tr('recién');
    if (d.inMinutes < 60) return '${d.inMinutes} min';
    if (d.inHours < 24) return '${d.inHours} h';
    return '${d.inDays} d';
  }

  /// Banners above the list. Both exist so the operator is never silently shown
  /// something other than the merchant's current, complete catalog: a stale
  /// price and a missing product are both money, and neither should be quiet.
  List<Widget> _notices() {
    final at = _fetchedAt;
    return [
      if (_source == _Source.cache && at != null)
        _Notice(
          icon: Icons.cloud_off,
          text: '${context.tr('Sin conexión')} · '
              '${context.tr('actualizado')} ${_ago(at)}',
        ),
      if (_unsellable > 0)
        _Notice(
          icon: Icons.info_outline,
          text: '$_unsellable ${context.tr(_unsellable == 1 ? 'producto oculto (precio no soportado)' : 'productos ocultos (precio no soportado)')}',
        ),
    ];
  }

  Widget _emptyState() {
    final offline = _source == _Source.offline;
    return PosBody(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(offline ? Icons.cloud_off : Icons.storefront_outlined,
                size: 48, color: AppColors.muted),
            const SizedBox(height: 12),
            Text(
              offline
                  ? context.tr('No se pudo leer el catálogo')
                  : context.tr('Este comercio todavía no publicó su menú'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              // Reaching here with products dropped means the merchant DOES
              // publish, just nothing chargeable — say so rather than implying
              // an empty catalog.
              _unsellable > 0
                  ? '$_unsellable ${context.tr(_unsellable == 1 ? 'producto oculto (precio no soportado)' : 'productos ocultos (precio no soportado)')}'
                  : context.tr('Podés cobrar un monto manual desde la caja.'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted, fontSize: 14),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: () => context.push('/paydesk'),
              icon: const Icon(Icons.calculate_outlined, size: 18),
              label: Text(context.tr('Caja registradora')),
            ),
          ],
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
            Text(context.tr('Resumen de compra'),
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
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
                            Text('${l.qty} ${context.tr(l.qty == 1 ? 'unidad' : 'unidades')}',
                                style: const TextStyle(
                                    color: AppColors.muted, fontSize: 12)),
                          ],
                        ),
                      ),
                      Text(
                          '${l.product.priceCurrency.code} '
                          '${formatToPreference(l.product.priceCurrency, l.subtotal)}',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                    ],
                  ),
                )),
            const Divider(height: 24),
            Builder(builder: (_) {
              final total = _totalSats;
              return FilledButton(
                // Null means a currency in this cart has no rate yet. The old
                // `?? 0` rendered a "Cobrar 0 sats" button; refusing to arm the
                // button is the honest version.
                onPressed: total == null
                    ? null
                    : () {
                        // Carry the cart lines to the ticket for printing.
                        setOrderItems([
                          for (final l in _cart.values)
                            OrderItem(
                                name: l.product.name,
                                unitPrice: l.product.priceValue,
                                qty: l.qty),
                        ]);
                        Navigator.of(ctx).pop();
                        goCheckout(context, sats: total, back: _backRoute);
                      },
                child: Text(total == null
                    ? context.tr('Esperando cotización…')
                    : '${context.tr('Cobrar')} ${formatToPreference(Currency.sat, total)} sats'),
              );
            }),
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
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: border,
      ),
      // Tapping anywhere on the tile adds the product (same as the + button).
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _add(p),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.name,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(
                          // The product's own currency, not a hardcoded ARS:
                          // USD needs its two decimals, which ARS formatting
                          // was flooring away.
                          '${p.priceCurrency.code} '
                          '${formatToPreference(p.priceCurrency, p.priceValue)}',
                          style: const TextStyle(
                              color: AppColors.muted, fontSize: 15)),
                    ],
                  ),
                ),
                if (qty > 0) ...[
                  _RoundBtn(icon: Icons.remove, onTap: () => _remove(p)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text('$qty',
                        style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                            color: inCart ? AppColors.primary : null)),
                  ),
                ],
                _RoundBtn(icon: Icons.add, onTap: () => _add(p)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A muted one-line banner above the menu list.
class _Notice extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Notice({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Icon(icon, size: 15, color: AppColors.muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text,
                style: const TextStyle(color: AppColors.muted, fontSize: 13)),
          ),
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
          padding: const EdgeInsets.all(10),
          child: Icon(icon, size: 24, color: AppColors.primary),
        ),
      ),
    );
  }
}
