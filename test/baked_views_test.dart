import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/core/widgets.dart';
import 'package:lawallet_pos/features/payment/invoice_view.dart';
import 'package:lawallet_pos/features/payment/nfc_charging_view.dart';

/// The Z92 bitmaps: the charge screen's glow and the invoice QR are drawn
/// once into images instead of live gradients and vectors.
void main() {
  testWidgets('the charge screen draws its glow from a bitmap', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: NfcChargingView(amountLabel: '\$ 1.000'))));
    await tester.pump(const Duration(milliseconds: 100));

    final glow = tester.widget<RawImage>(find.byType(RawImage).first);
    expect(glow.image, isNotNull);
    expect(find.text('Enviando invoice'), findsOneWidget);
  });

  testWidgets('the invoice QR is baked, and re-baked for a new invoice',
      (tester) async {
    Widget view(String? invoice) => MaterialApp(
          home: Scaffold(
            body: InvoiceView(
              satsStr: '21',
              arsStr: '30',
              invoice: invoice,
              nfcAvailable: false,
              tabEnabled: false,
              onCancel: () {},
              onCopy: () {},
              onCheck: () {},
              onAddTab: () {},
            ),
          ),
        );
    RawImage qr() => tester.widget<RawImage>(find.descendant(
        of: find.byType(BakedQr), matching: find.byType(RawImage)));

    await tester.pumpWidget(view('lnbc210n1pfirst'));
    await tester.pump(const Duration(seconds: 1));
    final first = qr().image!;

    await tester.pumpWidget(view('lnbc210n1psecond'));
    await tester.pump(const Duration(seconds: 1));
    expect(qr().image!.isCloneOf(first), isFalse);

    await tester.pumpWidget(const SizedBox());
  });
}
