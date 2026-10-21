import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lawallet_pos/core/flow_lock.dart';
import 'package:lawallet_pos/data/pricing/pricing_service.dart';
import 'package:lawallet_pos/domain/config/miniapp_pin.dart';
import 'package:lawallet_pos/features/miniapps/zape_screen.dart';
import 'package:lawallet_pos/features/settings/pin_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> enterPin(WidgetTester tester, String pin) async {
  await tester.enterText(find.byKey(const Key('miniapp-pin')), pin);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    miniappPin.value = null;
    lockedFlow.value = null;
  });

  /// Opens ZAPE, locks it, checks nothing else leads out, then unlocks.
  Future<void> lockAndUnlockZape(WidgetTester tester) async {
    final router = GoRouter(
      initialLocation: '/zape',
      redirect: (c, s) => lockRedirect(s.uri.path),
      routes: [
        GoRoute(path: '/', builder: (c, s) => const Text('home')),
        GoRoute(path: '/zape', builder: (c, s) => const ZapeScreen()),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    expect(find.byIcon(Icons.arrow_back), findsOneWidget, reason: 'unlocked');
    await tester.tap(find.byKey(const Key('flow-lock')));
    await tester.pump();
    expect(lockedFlow.value, '/zape');
    expect(find.byIcon(Icons.arrow_back), findsNothing);
    expect(find.byIcon(Icons.settings_outlined), findsNothing);
    router.go('/');
    await tester.pumpAndSettle();
    expect(find.text('home'), findsNothing, reason: 'the router holds it');
    await tester.tap(find.byKey(const Key('flow-unlock')));
    await tester.pumpAndSettle();
  }

  test('bigger tips print longer strips, capped at 40 points', () {
    expect(zapePresets.map(zapePoints), [4, 10, 19, 40]);
    expect(zapePoints(1), 1);
    expect(zapePoints(1000000), 40);
  });

  testWidgets('first screen offers the tip amounts', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    pricing.seedRates(const Rates(0.05, 0.0001));
    await tester.pumpWidget(const MaterialApp(home: ZapeScreen()));
    for (final sats in zapePresets) {
      expect(find.byKey(Key('zape-$sats')), findsOneWidget);
    }
    await tester.tap(find.byKey(const Key('zape-custom')));
    await tester.pump();
    expect(find.text('1'), findsOneWidget, reason: 'numpad is up');
  });

  testWidgets('without a PIN, unlocking goes straight to Home', (tester) async {
    await lockAndUnlockZape(tester);
    expect(find.byKey(const Key('miniapp-pin')), findsNothing);
    expect(find.text('home'), findsOneWidget);
    expect(lockedFlow.value, isNull);
  });

  testWidgets('a PIN set in settings guards the unlock and persists',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PinSettingsScreen()));
    expect(find.text('SETEAR PIN'), findsOneWidget);

    await tester.tap(find.byKey(const Key('pin-set')));
    await tester.pumpAndSettle();
    await enterPin(tester, '12'); // too short, stays open
    await enterPin(tester, '9876');
    await enterPin(tester, '9875'); // mismatch, stays open
    await enterPin(tester, '9876');
    expect(find.text('CAMBIAR PIN'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getString('miniappPin'),
        '9876');

    await lockAndUnlockZape(tester);
    expect(
        tester.getTopLeft(find.byKey(const Key('pin-cancel'))).dy,
        greaterThan(tester.getTopLeft(find.text('Desbloquear')).dy),
        reason: 'Cancelar sits below the action');
    await enterPin(tester, '0000');
    expect(find.text('home'), findsNothing);
    await enterPin(tester, '9876');
    expect(find.text('home'), findsOneWidget);
  });
}
