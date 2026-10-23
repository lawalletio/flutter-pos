import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/core/theme.dart';
import 'package:lawallet_pos/data/pricing/pricing_service.dart';
import 'package:lawallet_pos/domain/config/settings_state.dart';
import 'package:lawallet_pos/features/tip/tip_screen.dart';

void main() {
  tearDown(() {
    appSettings.value = const SettingsState();
  });

  Widget host() => MaterialApp(
        theme: buildAppTheme(),
        home: const TipScreen(amountSats: 10000),
      );

  /// The Z92's portrait screen: 720x1280 at density 240.
  void z92(WidgetTester tester) {
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('roulette shows only on options that unlock the wheel',
      (tester) async {
    tester.view.physicalSize = const Size(480, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    appSettings.value = const SettingsState();
    pricing.seedRates(const Rates(0.05, 0.0001));
    await tester.pumpWidget(host());
    await tester.pump();
    expect(find.byKey(const Key('tip-roulette')), findsNothing);
    expect(find.byKey(const Key('tip-sad')), findsOneWidget);

    appSettings.value = const SettingsState(
      prizePrintEnabled: true,
      wheelOffer: WheelOffer.tipOnly,
      prizeCoupons: [
        PrizeCoupon(id: 'cafe', text: 'Café', chancePercent: 20),
      ],
    );
    await tester.pump();
    expect(find.byKey(const Key('tip-roulette')), findsNWidgets(3));
    expect(find.byKey(const Key('tip-sad')), findsOneWidget);

    appSettings.value = const SettingsState(
      prizePrintEnabled: true,
      wheelOffer: WheelOffer.always,
      prizeCoupons: [
        PrizeCoupon(id: 'cafe', text: 'Café', chancePercent: 20),
      ],
    );
    await tester.pump();
    expect(find.byKey(const Key('tip-roulette')), findsNWidgets(3));
    expect(find.byKey(const Key('tip-sad')), findsOneWidget);
  });

  testWidgets('0% option skips the tip with the sad face', (tester) async {
    z92(tester);
    pricing.seedRates(const Rates(0.05, 0.0001));
    await tester.pumpWidget(host());
    await tester.pump();
    expect(find.text('0%'), findsOneWidget);
    expect(find.text('NO QUIERO DEJAR PROPINA'), findsOneWidget);
    expect(
        find.descendant(
            of: find.ancestor(
                of: find.text('0%'), matching: find.byType(InkWell)),
            matching: find.byKey(const Key('tip-sad'))),
        findsOneWidget);
  });

  testWidgets('totals line follows the settings toggle', (tester) async {
    z92(tester);
    pricing.seedRates(const Rates(0.05, 0.0001));
    await tester.pumpWidget(host());
    await tester.pump();
    // 3 tips + 0%.
    expect(find.textContaining('ARS'), findsNWidgets(5));

    appSettings.value = const SettingsState(tipShowTotals: false);
    await tester.pump();
    // Only the header's ≈ ARS remains.
    expect(find.textContaining('ARS'), findsOneWidget);
    expect(find.text('5%'), findsOneWidget);
  });

  testWidgets('fits the Z92 screen with and without totals', (tester) async {
    z92(tester);
    pricing.seedRates(const Rates(0.05, 0.0001));
    for (final show in [true, false]) {
      appSettings.value = SettingsState(tipShowTotals: show);
      await tester.pumpWidget(host());
      await tester.pump();
      expect(tester.takeException(), isNull);
      final bottom =
          tester.getBottomLeft(find.text('NO QUIERO DEJAR PROPINA')).dy;
      expect(bottom, lessThan(1280 / 1.5));
    }
  });
}
