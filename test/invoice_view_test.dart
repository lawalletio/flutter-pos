import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/core/amount_pad.dart';
import 'package:lawallet_pos/data/pricing/pricing_service.dart';
import 'package:lawallet_pos/domain/config/currencies.dart';
import 'package:lawallet_pos/domain/config/selected_currency.dart';
import 'package:lawallet_pos/features/payment/invoice_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    selectedCurrency.value = Currency.ars;
  });

  testWidgets('the switcher re-states the invoice amount at the live rate',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2340); // a phone, portrait
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    pricing.seedRates(const Rates(1.5, 0.001));
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
    expect(find.text('≈ ARS 1.500'), findsOneWidget);

    pricing.seedRates(const Rates(2, 0.001)); // the price moved
    await tester.pump();
    expect(find.text('≈ ARS 2.000'), findsOneWidget);

    await tester.tap(find.text('SAT'));
    await tester.pump();
    expect(find.text('1.000 sats'), findsOneWidget);

    await tester.tap(find.text('USD'));
    await tester.pump();
    expect(find.text('≈ USD 1.00'), findsOneWidget);

    // The next screen with a switcher opens on the same pick.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AmountPad(action: (_, __) => const SizedBox()),
      ),
    ));
    expect(find.text('USD 0.00'), findsOneWidget);

    pricing.notifier.value = null;
    await tester.pumpWidget(const SizedBox());
  });

  test('the currency pick survives a restart', () async {
    await setSelectedCurrency(Currency.sat);
    selectedCurrency.value = Currency.ars; // a fresh process
    await loadSelectedCurrency();
    expect(selectedCurrency.value, Currency.sat);
  });
}
