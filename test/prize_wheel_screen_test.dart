import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/core/theme.dart';
import 'package:lawallet_pos/domain/config/settings_state.dart';
import 'package:lawallet_pos/features/prize/prize_wheel_screen.dart';

void main() {
  // Every throw wins, so the end of a spin is the prize card.
  const sure = [PrizeCoupon(id: 'cafe', text: 'Café', chancePercent: 100)];

  Future<Offset> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    appSettings.value = const SettingsState(wheelDurationMs: 2000);
    addTearDown(() => appSettings.value = const SettingsState());
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: const PrizeWheelScreen(coupons: sure, miniapp: true),
    ));
    await tester.pump();
    // Left of the axle, level with it: dragging up or down turns the wheel.
    final box = tester.getRect(find.byKey(const Key('wheel-input')));
    final outer = 0.46 * box.height < 0.9 * box.width
        ? 0.46 * box.height
        : 0.9 * box.width;
    final band = box.height - 2 * outer < 96 ? 96 : box.height - 2 * outer;
    return Offset(box.right - outer * 0.6, box.top + band + outer);
  }

  bool spinning(WidgetTester tester) =>
      tester
          .widget<IconButton>(find.byKey(const Key('rueda-config')))
          .onPressed ==
      null;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 400 && spinning(tester); i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 800));
  }

  testWidgets('a slow drag asks for a harder throw and does not spin',
      (tester) async {
    final at = await open(tester);
    await tester.timedDragFrom(
        at, const Offset(0, 260), const Duration(milliseconds: 1500));
    await tester.pump();
    expect(find.text('¡Más fuerte!'), findsOneWidget);
    expect(spinning(tester), isFalse);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('¡Ganaste un premio!'), findsNothing);
  });

  testWidgets('a fast fling spins and lands on the prize', (tester) async {
    final at = await open(tester);
    await tester.flingFrom(at, const Offset(0, 300), 4000);
    await tester.pump();
    expect(spinning(tester), isTrue);
    await settle(tester);
    expect(find.text('¡Ganaste un premio!'), findsWidgets);
    // The miniapp resets for the next player once the card is tapped.
    await tester.tap(find.byKey(const Key('prize-reveal')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('prize-reveal')), findsNothing);
  });

  testWidgets('a double tap throws hard', (tester) async {
    final at = await open(tester);
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 120));
    expect(spinning(tester), isFalse, reason: 'one tap is not a throw');
    await tester.tapAt(at);
    await tester.pump();
    expect(spinning(tester), isTrue);
    await settle(tester);
    expect(find.text('¡Ganaste un premio!'), findsWidgets);
  });
}
