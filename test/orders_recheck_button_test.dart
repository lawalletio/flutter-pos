import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/data/pricing/pricing_service.dart';
import 'package:lawallet_pos/domain/order/current_order.dart';
import 'package:lawallet_pos/domain/order/orders_store.dart';
import 'package:lawallet_pos/features/orders/orders_screen.dart';

void main() {
  testWidgets(
      'pending recheckable order shows "Checkear"; paid order does not',
      (tester) async {
    // Seed rates so the ARS line renders and ensureLoaded skips the network.
    pricing.seedRates(const Rates(0.95, 0.0006));

    // Set the store directly (avoids SharedPreferences in a unit test).
    ordersStore.notifier.value = const [
      OrderRecord(
        id: 'p1',
        createdAt: 1783045050319,
        amountSats: 2500,
        summary: '2× Coca',
        verifyUrl: 'https://host/verify/abc', // → LUD-21 → canRecheck
        invoice: 'lnbc25',
        items: [OrderItem(name: 'Coca', unitPrice: 1500, qty: 2)],
      ),
      OrderRecord(
        id: 'paid1',
        createdAt: 1783045000000,
        amountSats: 800,
        summary: '1× Agua',
        isPaid: true,
      ),
    ];

    await tester.pumpWidget(const MaterialApp(home: OrdersScreen()));
    await tester.pump();

    // Both orders render.
    expect(find.text('2× Coca'), findsOneWidget);
    expect(find.text('1× Agua'), findsOneWidget);

    // Exactly one "Checkear" button — on the pending, recheckable order only.
    expect(find.text('Checkear'), findsOneWidget);

    // Clean up the shared singleton for other tests.
    ordersStore.notifier.value = const [];
  });
}
