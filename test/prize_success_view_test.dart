import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/core/theme.dart';
import 'package:lawallet_pos/features/payment/success_view.dart';

void main() {
  Widget host({
    String? prizeText,
    bool prizePrinted = false,
    bool printingPrize = false,
    Future<void> Function()? onPrintPrize,
  }) {
    return MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        backgroundColor: AppColors.background,
        body: PaymentSuccessView(
          satsStr: '1.000',
          arsStr: '15.000',
          prizeText: prizeText,
          prizePrinted: prizePrinted,
          printingPrize: printingPrize,
          onPrintPrize: onPrintPrize ?? () async {},
          onBack: () {},
        ),
      ),
    );
  }

  testWidgets('spin button shows only when the payment offers the wheel',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(host());
    await tester.pump();
    expect(find.byKey(const Key('spin-wheel-button')), findsNothing);

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        backgroundColor: AppColors.background,
        body: PaymentSuccessView(
          satsStr: '1.000',
          arsStr: '15.000',
          onSpinWheel: () => taps++,
          onBack: () {},
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('Tirar ruleta'), findsOneWidget);
    await tester.tap(find.byKey(const Key('spin-wheel-button')));
    await tester.pump();
    expect(taps, 1);

    await tester.pump(const Duration(milliseconds: 1000));
    final spin = tester.getRect(find.byKey(const Key('spin-wheel-button')));
    final back = tester.getRect(find.text('Volver'));
    expect(spin.width, greaterThan(500));
    expect(spin.height, greaterThan(56));
    expect(back.top, greaterThan(spin.bottom));
    expect(back.width, lessThan(spin.width));
  });

  testWidgets(
      'print-coupon button appears when the prize arrives after first frame',
      (tester) async {
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var prize = '';
    late StateSetter setHost;

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        backgroundColor: AppColors.background,
        body: StatefulBuilder(
          builder: (context, setState) {
            setHost = setState;
            return PaymentSuccessView(
              satsStr: '1.000',
              arsStr: '15.000',
              prizeText: prize.isEmpty ? null : prize,
              onPrintPrize: () async {},
              onBack: () {},
            );
          },
        ),
      ),
    ));
    await tester.pump();
    expect(find.byKey(const Key('prize-print-button')), findsNothing);

    setHost(() => prize = 'Café gratis');
    await tester.pump();
    // Lottery lands after the receipt; the second-beat delay is 1.5s.
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump(); // post-frame play
    await tester.pump(const Duration(milliseconds: 1100));

    expect(find.text('¡Ganaste un premio!'), findsOneWidget);
    expect(find.text('Café gratis'), findsOneWidget);
    expect(find.byKey(const Key('prize-print-button')), findsOneWidget);
    expect(find.text('Imprimir cupón'), findsOneWidget);

    final button = tester.widget<FilledButton>(
        find.byKey(const Key('prize-print-button')));
    expect(button.onPressed, isNotNull);

    final rect = tester.getRect(find.byKey(const Key('prize-print-button')));
    expect(rect.height, greaterThan(40));
    expect(rect.top, lessThan(1280));
    expect(rect.bottom, greaterThan(0));
  });

  testWidgets('already-printed auto-print does not leave the Impreso card',
      (tester) async {
    await tester.pumpWidget(host(
      prizeText: 'Birra',
      prizePrinted: true,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));

    expect(find.byKey(const Key('prize-grant-card')), findsNothing);
    expect(find.text('Impreso'), findsNothing);
  });

  testWidgets('print tap zooms the grant card out even if print fails',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(
      prizeText: 'Postre',
      prizePrinted: false,
      onPrintPrize: () async {
        taps++;
      },
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));

    await tester.tap(find.byKey(const Key('prize-print-button')));
    await tester.pump();
    expect(taps, 1);
    expect(find.byKey(const Key('prize-grant-card')), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byKey(const Key('prize-grant-card')), findsNothing);
    expect(find.byKey(const Key('prize-print-button')), findsNothing);
  });

  testWidgets('print tap zooms the grant card out immediately',
      (tester) async {
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var printed = false;
    var taps = 0;

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        backgroundColor: AppColors.background,
        body: StatefulBuilder(
          builder: (context, setState) {
            return PaymentSuccessView(
              satsStr: '1.000',
              arsStr: '15.000',
              prizeText: 'Café gratis',
              prizePrinted: printed,
              onPrintPrize: () async {
                taps++;
                setState(() => printed = true);
              },
              onBack: () {},
            );
          },
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));

    expect(find.byKey(const Key('prize-grant-card')), findsOneWidget);

    await tester.tap(find.byKey(const Key('prize-print-button')));
    await tester.pump();
    expect(taps, 1);
    expect(find.byKey(const Key('prize-grant-card')), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byKey(const Key('prize-grant-card')), findsNothing);
    expect(find.byKey(const Key('prize-print-button')), findsNothing);
    expect(find.text('¡Ganaste un premio!'), findsNothing);
  });
}
