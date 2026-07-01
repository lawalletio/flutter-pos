import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/data/pricing/pricing_service.dart';
import 'package:lawallet_pos/features/orders/orders_screen.dart';

void main() {
  testWidgets(
      'Total vendido shows and "Eliminar todas" clears after confirmation',
      (tester) async {
    // Seed rates so the ARS line renders and ensureLoaded skips the network.
    pricing.seedRates(const Rates(0.95, 0.0006));

    await tester.pumpWidget(const MaterialApp(home: OrdersScreen()));
    await tester.pump();

    // Summary + delete button are present.
    expect(find.text('Total vendido'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Eliminar todas'), findsOneWidget);

    // Tap the delete button → confirmation prompt appears.
    await tester.tap(find.widgetWithText(OutlinedButton, 'Eliminar todas'));
    await tester.pumpAndSettle();
    expect(find.text('¿Eliminar todas las órdenes?'), findsOneWidget);

    // Cancel keeps the orders.
    await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
    await tester.pumpAndSettle();
    expect(find.text('Total vendido'), findsOneWidget);

    // Confirm clears them → empty state.
    await tester.tap(find.widgetWithText(OutlinedButton, 'Eliminar todas'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Eliminar todas'));
    await tester.pumpAndSettle();
    expect(find.text('Todavía no hay órdenes creadas.'), findsOneWidget);
  });
}
