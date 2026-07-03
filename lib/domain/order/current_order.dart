import 'package:flutter/foundation.dart';

/// A single line on the ticket: product name, unit price (in ARS), quantity.
@immutable
class OrderItem {
  final String name;
  final num unitPrice;
  final int qty;
  const OrderItem(
      {required this.name, required this.unitPrice, required this.qty});

  Map<String, dynamic> toJson() =>
      {'name': name, 'unitPrice': unitPrice, 'qty': qty};

  factory OrderItem.fromJson(Map<String, dynamic> j) => OrderItem(
        name: j['name'] as String? ?? '',
        unitPrice: (j['unitPrice'] as num?) ?? 0,
        qty: (j['qty'] as num?)?.toInt() ?? 1,
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
