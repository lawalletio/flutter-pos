import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
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
  });

  Future<void> openZape(WidgetTester tester) async {
    final router = GoRouter(initialLocation: '/zape', routes: [
      GoRoute(path: '/', builder: (c, s) => const Text('home')),
      GoRoute(path: '/zape', builder: (c, s) => const ZapeScreen()),
    ]);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.byKey(const Key('miniapp-close')));
    await tester.pumpAndSettle();
  }

  testWidgets('without a PIN, ZAPE closes straight to Home', (tester) async {
    await openZape(tester);
    expect(find.byKey(const Key('miniapp-pin')), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('a PIN set in settings locks ZAPE and persists', (tester) async {
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

    await openZape(tester);
    expect(
        tester.getTopLeft(find.byKey(const Key('pin-cancel'))).dy,
        greaterThan(tester.getTopLeft(find.text('Salir')).dy),
        reason: 'Cancelar sits below the action');
    await enterPin(tester, '0000');
    expect(find.text('home'), findsNothing);
    await enterPin(tester, '9876');
    expect(find.text('home'), findsOneWidget);
  });
}
