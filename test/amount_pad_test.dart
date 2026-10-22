import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/core/amount_pad.dart';
import 'package:lawallet_pos/core/theme.dart';
import 'package:lawallet_pos/data/pricing/pricing_service.dart';

void main() {
  testWidgets('switching currency keeps the amount; reset clears it',
      (tester) async {
    tester.view
      ..physicalSize = const Size(720, 1440)
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    pricing.seedRates(const Rates(0.05, 0.0001)); // 1 sat = 0.05 ARS
    final reset = ValueNotifier(0);
    var sats = -1;
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: AmountPad(
          reset: reset,
          action: (context, s) {
            sats = s;
            return const SizedBox.shrink();
          },
        ),
      ),
    ));

    await tester.tap(find.text('SAT'));
    await tester.pump();
    for (final d in ['2', '00', '0']) {
      await tester.tap(find.text(d));
      await tester.pump();
    }
    expect(find.text('2.000 sats'), findsOneWidget);
    expect(sats, 2000);

    await tester.tap(find.text('ARS'));
    await tester.pump();
    expect(find.text('ARS 100'), findsOneWidget);
    expect(sats, 2000, reason: 'the value carries over, not the digits');

    await tester.tap(find.text('USD'));
    await tester.pump();
    expect(find.text('USD 0.20'), findsOneWidget);
    expect(sats, 2000);

    await tester.tap(find.byIcon(Icons.backspace_outlined));
    await tester.pump();
    expect(sats, 200, reason: 'USD 0.02');

    await tester.tap(find.text('SAT'));
    await tester.pump();
    expect(find.text('200 sats'), findsOneWidget, reason: 'back to sats');

    reset.value++;
    await tester.pump();
    expect(sats, 0);

    // Rates that arrive later redraw the conversion.
    await tester.tap(find.text('ARS'));
    await tester.tap(find.text('5'));
    await tester.pump();
    expect(find.text('≈ 100 sats'), findsOneWidget);
    pricing.seedRates(const Rates(0.1, 0.0001));
    await tester.pump();
    expect(find.text('≈ 50 sats'), findsOneWidget);
  });
}
