import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/core/router.dart';
import 'package:lawallet_pos/data/lnurl/lnurl_service.dart';
import 'package:lawallet_pos/data/pricing/pricing_service.dart';
import 'package:lawallet_pos/domain/config/settings_state.dart';
import 'package:lawallet_pos/domain/order/current_order.dart';
import 'package:lawallet_pos/domain/order/orders_store.dart';
import 'package:lawallet_pos/features/payment/success_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A provider whose LUD-21 verify answers [settled].
class _VerifyLnurl extends LnurlService {
  _VerifyLnurl(this.settled);
  final bool settled;
  @override
  Future<bool> checkSettled(String verifyUrl) async => settled;
}

/// Pending, couponed, tipped — everything the replay must read from the order.
const _order = OrderRecord(
  id: 'o1',
  createdAt: 1783045050319,
  amountSats: 900,
  summary: '2× Coca',
  verifyUrl: 'https://host/verify/abc',
  invoice: 'lnbc9',
  items: [OrderItem(name: 'Coca', unitPrice: 500, qty: 2)],
  couponName: 'Vaso',
  discountSats: 100,
  tipSats: 50,
);

void main() {
  late List<Map> printed;
  final original = lnurl;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    pricing.seedRates(const Rates(0.95, 0.0006));
    printed = [];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('pos/printer'),
        (call) async {
      if (call.method == 'print') printed.add(call.arguments as Map);
      return 0;
    });
    messenger.setMockMethodCallHandler(
        const MethodChannel('pos/sounds'), (_) async => null);
    // Prizes on, wheel offered only after a tip: the order's tip decides.
    appSettings.value = const SettingsState(
      prizePrintEnabled: true,
      prizeCoupons: [PrizeCoupon(id: 'cafe', text: 'Café', chancePercent: 100)],
    );
    // Something else is rung up meanwhile; the replay must leave it alone.
    currentOrderItems.value = const [OrderItem(name: 'Agua', unitPrice: 300, qty: 1)];
    ordersStore.notifier.value = const [_order];
  });

  tearDown(() {
    lnurl = original;
    appSettings.value = const SettingsState();
    currentOrderItems.value = const [];
    ordersStore.notifier.value = const [];
  });

  Future<void> recheck(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp.router(routerConfig: appRouter));
    appRouter.go('/orders');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Checkear'));
    await tester.pump(); // dialog
    await tester.pump(); // post-frame verify
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Cerrar'));
    // The success screen animates forever; step time instead of settling.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('a confirmed recheck continues into the normal paid flow',
      (tester) async {
    lnurl = _VerifyLnurl(true);
    await recheck(tester);

    expect(ordersStore.notifier.value.single.isPaid, isTrue);
    // The ticket is the order's, not the live cart's.
    expect(printed, hasLength(1));
    expect((printed.single['items'] as List).single['name'], 'Coca');
    expect(printed.single['couponName'], 'Vaso');
    expect(printed.single['totalSats'], '900');
    expect(printed.single['discount'], isNotNull);
    // Success screen with the coupon, and the wheel because the order tipped.
    expect(find.byType(PaymentSuccessView), findsOneWidget);
    expect(find.text('Vaso'), findsOneWidget);
    expect(find.text('Tirar ruleta'), findsOneWidget);

    await tester.tap(find.text('Volver').first);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(appRouter.routerDelegate.currentConfiguration.uri.path, '/orders');
    expect(currentOrderItems.value.single.name, 'Agua');
  });

  testWidgets('an unconfirmed recheck stays on Orders and prints nothing',
      (tester) async {
    lnurl = _VerifyLnurl(false);
    await recheck(tester);

    expect(ordersStore.notifier.value.single.isPaid, isFalse);
    expect(printed, isEmpty);
    expect(find.byType(PaymentSuccessView), findsNothing);
    expect(appRouter.routerDelegate.currentConfiguration.uri.path, '/orders');
  });
}
