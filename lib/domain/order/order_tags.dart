import '../config/currencies.dart';
import '../coupon/coupon.dart';
import 'current_order.dart';

/// A coupon as an order records it: definition id, benefit type, name.
typedef OrderCoupon = ({String id, String type, String name});

/// What an order says about itself, as nostr tags.
///
/// The vocabulary is the merchant panel's (`src/lib/domain/zap-order.ts`),
/// which reads these off the kind-9734 to show what a sale contained:
///
/// ```
/// ["item", d, qty, unitAmount, currency]   one per line
/// ["items_count", n]
/// ["total", amount, currency]              GROSS, per currency
/// ["discount", amount, currency]           what the coupons took off, summed
/// ["coupon", id, type, name]               one per coupon applied
/// ```
///
/// Gross and discount travel separately on purpose: gross − discount is what
/// was charged, and the net alone cannot be told apart from a cheaper basket.
///
/// Shared by the zap request sent to the LNURL callback and the order filed
/// with a coupon redemption, so a sale reads the same either way.
///
/// [coupons] is every coupon applied — the ones the cart's products carry plus
/// a scanned one — and [discounts] is what they took off together.
List<List<String>> orderTags({
  required List<OrderItem> lines,
  List<DiscountEntry> discounts = const [],
  List<OrderCoupon> coupons = const [],
}) {
  final gross = <Currency, num>{};
  for (final l in lines) {
    gross.update(l.priceCurrency, (v) => v + l.unitPrice * l.qty,
        ifAbsent: () => l.unitPrice * l.qty);
  }

  return [
    // `%` → full-width `％`: Primal's LNURL callback answers 500 to a zap
    // request carrying a bare `%` ("5% al escabio"), so every invoice failed.
    for (final c in coupons)
      ['coupon', c.id, c.type, c.name.replaceAll('%', '％')],
    for (final e in gross.entries) ['total', '${e.value}', e.key.code],
    for (final d in discounts) ['discount', '${d.amount}', d.currency.code],
    if (lines.isNotEmpty)
      ['items_count', '${lines.fold<int>(0, (n, l) => n + l.qty)}'],
    // Lines without a `d` are dropped, not faked: a paydesk charge has no
    // product behind it, and an invented id would corrupt the merchant's
    // per-product reporting.
    for (final l in lines)
      if (l.d != null && l.d!.isNotEmpty)
        ['item', l.d!, '${l.qty}', '${l.unitPrice}', l.priceCurrency.code],
  ];
}

/// [tags] with the per-line detail shed, for when the whole set will not fit.
///
/// Keeps the coupon, the totals and the discount — the parts the merchant is
/// owed — rather than losing the entire record to its own length.
List<List<String>> withoutLineDetail(List<List<String>> tags) =>
    tags.where((t) => t[0] != 'item').toList();
