import '../config/currencies.dart';
import '../coupon/coupon.dart';
import 'current_order.dart';

/// What an order says about itself, as nostr tags.
///
/// The vocabulary is the merchant panel's (`src/lib/domain/zap-order.ts`),
/// which reads these off the kind-9734 to show what a sale contained:
///
/// ```
/// ["item", d, qty, unitAmount, currency]   one per line
/// ["items_count", n]
/// ["total", amount, currency]              GROSS, per currency
/// ["discount", amount, currency]           what a coupon took off
/// ["coupon", id, type, name]
/// ```
///
/// Gross and discount travel separately on purpose: gross − discount is what
/// was charged, and the net alone cannot be told apart from a cheaper basket.
///
/// Shared by the zap request sent to the LNURL callback and the order filed
/// with a coupon redemption, so a sale reads the same either way.
List<List<String>> orderTags({
  required List<OrderItem> lines,
  List<DiscountEntry> discounts = const [],
  String? couponId,
  String? couponType,
  String? couponName,
}) {
  final gross = <Currency, num>{};
  for (final l in lines) {
    gross.update(l.priceCurrency, (v) => v + l.unitPrice * l.qty,
        ifAbsent: () => l.unitPrice * l.qty);
  }

  return [
    if (couponId != null)
      ['coupon', couponId, couponType ?? '', couponName ?? ''],
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
