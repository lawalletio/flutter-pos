import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/data/pricing/pricing_service.dart';
import 'package:lawallet_pos/features/payment/invoice_view.dart';

void main() {
  testWidgets('the switcher re-states the invoice amount at the live rate',
      (tester) async {
    pricing.notifier.value = const Rates(1.5, 0.001);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InvoiceView(
          sats: 1000,
          invoice: null,
          nfcAvailable: false,
          tabEnabled: false,
          onCancel: () {},
          onCopy: () {},
          onCheck: () {},
          onAddTab: () {},
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('1.000 sats'), findsOneWidget);

    await tester.tap(find.text('ARS'));
    await tester.pump();
    expect(find.text('≈ ARS 1.500'), findsOneWidget);

    pricing.notifier.value = const Rates(2, 0.001); // the price moved
    await tester.pump();
    expect(find.text('≈ ARS 2.000'), findsOneWidget);

    await tester.tap(find.text('USD'));
    await tester.pump();
    expect(find.text('≈ USD 1.00'), findsOneWidget);

    pricing.notifier.value = null;
    await tester.pumpWidget(const SizedBox());
  });
}
