import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lawallet_pos/core/flow_lock.dart';
import 'package:lawallet_pos/core/theme.dart';
import 'package:lawallet_pos/domain/config/miniapp_pin.dart';
import 'package:lawallet_pos/domain/config/settings_state.dart';
import 'package:lawallet_pos/features/miniapps/rueda_screen.dart';
import 'package:lawallet_pos/features/settings/settings_screen.dart';

void main() {
  tearDown(() {
    appSettings.value = const SettingsState();
    ruedaUseCustom.value = false;
    ruedaCustomPrizes.value = const [];
  });

  test('custom prizes stay in memory and edit like the settings ones', () {
    expect(addRuedaPrize('Birra', 30), isTrue);
    final birra = ruedaCustomPrizes.value.single;
    expect(updateRuedaPrize(birra.id, '', 10), isFalse);
    expect(updateRuedaPrize(birra.id, 'Birra 2x1', 40), isTrue);
    expect(ruedaCustomPrizes.value.single.text, 'Birra 2x1');
    expect(appSettings.value.prizeCoupons, isEmpty);
    removeRuedaPrize(birra.id);
    expect(ruedaCustomPrizes.value, isEmpty);
  });

  testWidgets('plays settings coupons or custom ones, config behind the gear',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    miniappPin.value = null;
    appSettings.value = const SettingsState(prizeCoupons: [
      PrizeCoupon(id: 'cafe', text: 'Café gratis', chancePercent: 25),
    ]);
    final router = GoRouter(initialLocation: '/rueda', routes: [
      GoRoute(path: '/', builder: (c, s) => const Text('home')),
      GoRoute(path: '/rueda', builder: (c, s) => const RuedaScreen(), routes: [
        GoRoute(path: 'config', builder: (c, s) => const WheelSettingsScreen()),
      ]),
    ]);
    await tester.pumpWidget(
        MaterialApp.router(theme: buildAppTheme(), routerConfig: router));
    await tester.pump();
    expect(find.byKey(const Key('wheel-input')), findsOneWidget,
        reason: 'settings coupons');

    ruedaUseCustom.value = true;
    await tester.pump();
    expect(find.text('No hay premios'), findsOneWidget,
        reason: 'custom list starts empty');

    expect(addRuedaPrize('  ', 50), isFalse);
    expect(addRuedaPrize('Birra', 50), isTrue);
    await tester.pump();
    expect(find.byKey(const Key('wheel-input')), findsOneWidget,
        reason: 'custom prize spins');

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Configurar rueda'), findsOneWidget);
    expect(find.text('Birra'), findsOneWidget);
    expect(find.text('Café gratis'), findsNothing);

    router.pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('flow-lock')));
    await tester.pump();
    expect(find.byIcon(Icons.settings_outlined), findsNothing,
        reason: 'config is out of reach while locked');
    await tester.tap(find.byKey(const Key('flow-unlock')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('home'), findsOneWidget);
    expect(lockedFlow.value, isNull);
  });
}
