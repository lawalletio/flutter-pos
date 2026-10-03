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
}
