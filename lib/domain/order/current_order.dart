import 'package:flutter/foundation.dart';

import '../config/currencies.dart';

/// A single line on the ticket: product name, unit price, quantity.
@immutable
class OrderItem {
  final String name;
  final num unitPrice;
  final int qty;

  /// The catalog `d` (NIP-99 uuid) this line came from, or null for a synthetic
  /// line — a paydesk charge has no product behind it. Coupons scoped to
  /// products match on this, so a null `d` is simply never eligible.
  final String? d;

  /// The currency [unitPrice] is quoted in. Null means ARS, which is what every
  /// line persisted before this field existed was assumed to be.
  final Currency? currency;

  /// [currency] with the legacy default applied. Everything that prices a line
  /// goes through this, so the null never leaks past the model.
  Currency get priceCurrency => currency ?? Currency.ars;

  const OrderItem({
    required this.name,
    required this.unitPrice,
    required this.qty,
    this.d,
    this.currency,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'unitPrice': unitPrice,
        'qty': qty,
        if (d != null) 'd': d,
        if (currency != null) 'currency': currency!.code,
      };

  factory OrderItem.fromJson(Map<String, dynamic> j) => OrderItem(
        name: j['name'] as String? ?? '',
        unitPrice: (j['unitPrice'] as num?) ?? 0,
        qty: (j['qty'] as num?)?.toInt() ?? 1,
        d: j['d'] as String?,
        currency: switch (j['currency']) {
          final String c => CurrencyX.tryFromCode(c),
          _ => null,
        },
      );
}

/// The line items of the order currently being charged, surfaced to the payment
/// screen so they can be printed on the ticket. Set at checkout (menu cart),
/// cleared on [resetOrder]. Manual (paydesk) charges set an empty list.
final ValueNotifier<List<OrderItem>> currentOrderItems =
    ValueNotifier<List<OrderItem>>(const []);

void setOrderItems(List<OrderItem> items) =>
    currentOrderItems.value = List.unmodifiable(items);

void clearOrderItems() => currentOrderItems.value = const [];
