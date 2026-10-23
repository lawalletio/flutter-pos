import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lawallet_pos/core/flow_lock.dart';
import 'package:lawallet_pos/core/widgets.dart' show BakedQr;
import 'package:lawallet_pos/features/cards/cards_api.dart';
import 'package:lawallet_pos/features/cards/cards_screen.dart';
import 'package:lawallet_pos/features/cards/cards_topup.dart';
import 'package:lawallet_pos/features/cards/cards_widgets.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:lawallet_pos/data/lnurl/lnurl_service.dart';
import 'package:lawallet_pos/domain/coupon/coupon.dart';
import 'package:lawallet_pos/domain/order/current_order.dart';
import 'package:lawallet_pos/domain/order/order_tags.dart';
import 'package:lawallet_pos/features/payment/invoice_view.dart';
import 'package:lawallet_pos/features/payment/nfc_charging_view.dart';
import 'package:lawallet_pos/data/lnurl/bech32_lnurl.dart';
import 'package:lawallet_pos/data/pricing/pricing_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

String jwt(Map<String, Object?> claims) {
  String seg(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${seg({'alg': 'HS256'})}.${seg(claims)}.sig';
}

final _future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;

/// Answers each request with [routes]`[METHOD path]` → (status, body).
class FakeNet implements HttpClientAdapter {
  FakeNet(this.routes);
  final Map<String, (int, Object)> routes;
  final calls = <String>[];

  @override
  Future<ResponseBody> fetch(
      RequestOptions o, Stream<Uint8List>? _, Future<void>? __) async {
    final key = '${o.method} ${o.uri.path}';
    calls.add(key);
    final (code, body) = routes[key] ?? (404, {'message': 'nope'});
    return ResponseBody.fromString(jsonEncode(body), code, headers: {
      'content-type': ['application/json']
    });
  }

  @override
  void close({bool force = false}) {}
}

/// Every request fails before reaching a server.
class OfflineNet implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
          RequestOptions o, Stream<Uint8List>? _, Future<void>? __) =>
      throw DioException(requestOptions: o, message: 'offline');

  @override
  void close({bool force = false}) {}
}

/// A camera that shows nothing and scans what the test hands it.
class FakeScanner extends MobileScannerPlatform {
  final scans = StreamController<BarcodeCapture?>.broadcast();

  @override
  Stream<BarcodeCapture?> get barcodesStream => scans.stream;
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();
  @override
  Widget buildCameraView() => const SizedBox.expand();
  @override
  Future<MobileScannerViewAttributes> start(StartOptions startOptions) async =>
      const MobileScannerViewAttributes(
          cameraDirection: CameraFacing.back,
          currentTorchMode: TorchState.unavailable,
          size: Size(720, 1280));
  @override
  Future<void> stop() async {}
  @override
  Future<void> updateScanWindow(Rect? window) async {}
  @override
  Future<void> dispose() async {}
}

/// Mints a fake invoice, settles when told to, and pays it with any card.
class FakeLnurl extends LnurlService {
  FakeLnurl({this.fail, this.decline});

  /// Thrown by [requestInvoice].
  final Object? fail;

  /// Thrown by [payWithCard], as a card server refusing the charge.
  final LnurlException? decline;
  bool settled = false;
  final cardsPaid = <String>[];

  @override
  Future<LnurlInvoice> requestInvoice(String address, int sats,
      {List<String> relays = const [],
      String? recipientPubkey,
      List<OrderItem> lines = const [],
      List<DiscountEntry> discounts = const [],
      List<OrderCoupon> coupons = const []}) async {
    if (fail != null) throw fail!;
    return LnurlInvoice(pr: 'lnbc${sats}n1fake', verify: 'https://x.io/v/1');
  }

  @override
  Future<bool> checkSettled(String verifyUrl) async => settled;

  @override
  Future<void> payWithCard(String cardUrl, String invoice) async {
    cardsPaid.add(cardUrl);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (decline != null) throw decline!;
    settled = true;
  }
}

Matcher apiError(String message) => throwsA(
    isA<CardsApiException>().having((e) => e.message, 'message', message));

CardsApi apiWith(FakeNet net) => CardsApi(
    dio: Dio(BaseOptions(
        responseType: ResponseType.plain, validateStatus: (_) => true))
      ..httpClientAdapter = net);

const cardUrl = 'lnurlw://beta.lawallet.io/api/cards/abc-1/scan?p=A1B2&c=C3D4';

/// Methods the screen called on the NFC channel.
final nfcCalls = <String>[];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await CardsAuth.instance
        .login(jwt({'apiUrl': 'beta.lawallet.io/', 'exp': _future}));
    CardsAuth.instance.setAutoPrint(false);
  });

  /// Pumps the miniapp at /cards (behind a '/' home) on a Z92-sized screen.
  /// Returns the printed slips, a card tap, and a settle that lets Dio and
  /// the QR PNG run on real async while the animations stay on fake time.
  Future<
      ({
        List<Map> printed,
        void Function(String url) tap,
        Future<void> Function() settle,
      })> pumpCards(WidgetTester tester, FakeNet net) async {
    final printed = <Map>[];
    nfcCalls.clear();
    messenger.setMockMethodCallHandler(const MethodChannel('pos/nfc'),
        (call) async {
      nfcCalls.add(call.method);
      return call.method == 'stopSession' ? null : true;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('pos/printer'),
        (call) async {
      if (call.method.startsWith('printCard')) {
        printed.add(call.arguments as Map);
      }
      return call.method == 'isAvailable' ? true : 0;
    });
    MockStreamHandlerEventSink? sink;
    messenger.setMockStreamHandler(const EventChannel('pos/nfc/tags'),
        MockStreamHandler.inline(onListen: (_, s) {
      sink = s;
    }));
    tester.view
      ..physicalSize = const Size(720, 1440) // the Z92's portrait screen
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final router = GoRouter(initialLocation: '/cards', routes: [
      GoRoute(path: '/', builder: (_, __) => const Text('home')),
      GoRoute(path: '/hub', builder: (_, __) => const Text('hub')),
      GoRoute(
          path: '/cards', builder: (_, __) => CardsScreen(api: apiWith(net))),
    ]);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 1));
      }
    }

    await settle();
    return (
      printed: printed,
      tap: (String url) => sink!.success(url),
      settle: settle
    );
  }

  const unowned = {
    'id': 'abc-1',
    'design': {'imageUrl': ''}
  };
  const owner = {
    'owned': true,
    'primaryAddress': 'a@x.io',
    'lightningAddresses': ['a@x.io'],
    'cardRecoveryEnabled': true,
    'balanceSats': 21,
  };
  const activation = (
    200,
    {'qrPayload': 'https://beta.lawallet.io/wallet/activate/abc-1?t=1'}
  );

  test('parses tokens, card urls and domains like card-manager', () {
    final c = decodeJwt(jwt({
      'apiUrl': 'x.io',
      'scopes': ['cards:write'],
      'exp': 10
    }))!;
    expect(c.scopes, ['cards:write']);
    expect(isJwtExpired(c), isTrue);
    expect(decodeJwt('nope'), isNull);
    expect(normalizeBaseUrl('beta.lawallet.io//'), 'https://beta.lawallet.io');
    expect(CardsAuth.instance.baseUrl, 'https://beta.lawallet.io');
    expect(resolveCardId(cardUrl), 'abc-1');
    expect(resolveCardId(' lnurlw://abc/ '), 'abc');
    expect(parseSun(cardUrl)?.p, 'A1B2');
    expect(parseSun('https://x/api/cards/a?p=11'), isNull);
    expect(
        cardDomain(
            'https://www.beta.lawallet.io:443/wallet/activate/x?tag=recover'),
        'beta.lawallet.io');
    expect(formatSats(12345), '12,345 sats');
    expect(formatSats(1), '1 sat');
  });

  test('maps API answers and errors like card-manager', () async {
    final net = FakeNet({
      'GET /api/cards/abc-1': (
        200,
        {'id': 'abc-1', 'username': 'ana', 'disabled': true}
      ),
      'POST /api/cards/abc-1/activation-tokens': (409, {'message': 'busy'}),
      'POST /api/cards/abc-1/recovery-tokens': (
        403,
        {
          'error': {'message': 'Recovery off'}
        }
      ),
    });
    final api = apiWith(net);
    final card = await api.getCard(cardUrl, sun: parseSun(cardUrl));
    expect(card.status, 'Paused');
    expect(card.lightningAddress, 'ana@beta.lawallet.io');
    expect(await api.getOwner('abc-1'), isNull); // older backend: 404
    expect(
        () => api.mintActivation('abc-1'),
        throwsA(isA<CardsApiException>().having((e) => e.message, 'message',
            'Another QR was just issued — try again.')));
    expect(
        () => api.mintRecovery('abc-1', card.sun!),
        throwsA(isA<CardsApiException>()
            .having((e) => e.message, 'message', 'Recovery off')));

    final expired = apiWith(FakeNet({'GET /api/cards/x': (401, {})}));
    await expectLater(expired.getCard('x'), throwsA(isA<CardsApiException>()));
    expect(CardsAuth.instance.loggedIn.value, isFalse);
  });

  test('API: missing payloads, offline, odd bodies, signed out', () async {
    final api = apiWith(FakeNet({
      'POST /api/cards/a/activation-tokens': (200, {}),
      'POST /api/cards/a/recovery-tokens': (200, {}),
      'GET /api/cards/odd': (200, 'ok'),
      'GET /api/cards/down': (502, {}),
    }));
    await expectLater(api.getCard('down'), apiError('Error (HTTP 502).'));
    await expectLater(api.mintActivation('a'),
        apiError('Activation response missing qrPayload.'));
    await expectLater(api.mintRecovery('a', const Sun('p', 'c')),
        apiError('Recovery response missing qrPayload.'));
    await expectLater(
        api.getCard('odd'), apiError('Unexpected server response.'));
    final offline = CardsApi(dio: Dio()..httpClientAdapter = OfflineNet());
    await expectLater(offline.getCard('a'), apiError('offline'));
    expect(CardsApiException('boom').toString(), 'boom');

    CardsAuth.instance.logout();
    await expectLater(CardsApi().getCard('a'), apiError('Not authenticated.'));
  });

  testWidgets('loaders while it works; a failed activate or recover says why',
      (tester) async {
    final net = FakeNet({
      'GET /api/cards/abc-1': (200, unowned),
      'POST /api/cards/abc-1/activation-tokens': (409, {}),
    });
    final app = await pumpCards(tester, net);
    app.tap(cardUrl);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(find.text('Getting card details...'), findsOneWidget);
    await app.settle();

    await tester.tap(find.byKey(const Key('cards-activate')));
    await tester.pump();
    expect(find.text('Generating activation QR…'), findsOneWidget);
    await app.settle();
    expect(
        find.text('Another QR was just issued — try again.'), findsOneWidget);
    await tester.tap(find.text('Back'));
    await tester.pump();

    net.routes
      ..['GET /api/cards/abc-1'] = (200, {'id': 'abc-1', 'username': 'a'})
      ..['GET /api/cards/abc-1/owner'] = (200, owner)
      ..['POST /api/cards/abc-1/recovery-tokens'] =
          (403, {'message': 'Recovery is off'});
    app.tap(cardUrl);
    await app.settle();
    await tester.tap(find.byKey(const Key('cards-recover')));
    await tester.pump();
    expect(find.text('Generating recovery QR…'), findsOneWidget);
    await app.settle();
    expect(find.text('Recovery is off'), findsOneWidget);
  });

  testWidgets('owner fallbacks: first address, no balance, no address',
      (tester) async {
    final net = FakeNet({
      'GET /api/cards/abc-1': (200, {'id': 'abc-1', 'username': 'a'}),
      'GET /api/cards/abc-1/owner': (
        200,
        {
          'owned': true,
          'lightningAddresses': ['b@x.io'],
          'cardRecoveryEnabled': true,
        }
      ),
    });
    final app = await pumpCards(tester, net);
    app.tap(cardUrl);
    await app.settle();
    expect(find.text('⚡ b@x.io'), findsOneWidget, reason: 'no primary set');
    expect(find.text('Balance unavailable'), findsOneWidget);
    expect(find.byKey(const Key('cards-topup')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    net.routes['GET /api/cards/abc-1/owner'] =
        (200, {'owned': true, 'cardRecoveryEnabled': true});
    app.tap(cardUrl);
    await app.settle();
    expect(find.text('No lightning address'), findsOneWidget);
    expect(find.byKey(const Key('cards-topup')), findsNothing,
        reason: 'nowhere to send the sats');
    expect(find.byKey(const Key('cards-recover')), findsOneWidget);
  });

  testWidgets('tap → detail → activate → print → back to scanning',
      (tester) async {
    final net = FakeNet({
      'GET /api/cards/abc-1': (200, unowned),
      'POST /api/cards/abc-1/activation-tokens': activation,
    });
    final app = await pumpCards(tester, net);
    expect(find.text('Tap your card'), findsOneWidget);

    app.tap(''); // a tag without a LaWallet lnurl
    await tester.pump();
    expect(find.text('Blank card'), findsOneWidget);
    expect(nfcCalls, contains('vibrate'), reason: 'a taken tap buzzes');
    await tester.tap(find.text('Back'));
    await tester.pump();

    app.tap(cardUrl);
    await app.settle();
    expect(find.text('Not activated'), findsOneWidget);

    await tester.tap(find.byKey(const Key('cards-activate')));
    await app.settle();
    expect(find.text('Print to activate your card'), findsOneWidget);
    await app.settle();
    await tester.tap(find.byKey(const Key('cards-print')));
    await tester.pump();
    expect(find.text('Printing…'), findsOneWidget);
    await app.settle();
    await tester.pump(const Duration(milliseconds: 2100));
    expect(find.text('Tap your card'), findsOneWidget);
    expect(app.printed.single['subtitle'], 'Activate your card');
    expect(app.printed.single['caption'], 'beta.lawallet.io');
  });

  testWidgets('auto-print mints and prints an unowned card on tap',
      (tester) async {
    CardsAuth.instance.setAutoPrint(true);
    final app = await pumpCards(
        tester,
        FakeNet({
          'GET /api/cards/abc-1': (200, unowned),
          'POST /api/cards/abc-1/activation-tokens': activation,
        }));
    app.tap(cardUrl);
    await app.settle();
    await app.settle();
    expect(find.text('Printing…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2100));
    expect(app.printed, hasLength(1));
    expect(find.text('Tap your card'), findsOneWidget);
  });

  testWidgets('an owned card shows its owner and recovers with the tap',
      (tester) async {
    final net = FakeNet({
      'GET /api/cards/abc-1': (200, {'id': 'abc-1', 'username': 'a'}),
      'GET /api/cards/abc-1/owner': (
        200,
        {
          ...owner,
          'lightningAddresses': [for (final n in 'abcde'.split('')) '$n@x.io'],
        }
      ),
      'POST /api/cards/abc-1/recovery-tokens': (
        200,
        {
          'qrPayload':
              'https://beta.lawallet.io/wallet/activate/abc-1?tag=recover'
        }
      ),
    });
    final app = await pumpCards(tester, net);
    app.tap(cardUrl);
    await app.settle();
    expect(find.text('Activated'), findsOneWidget);
    expect(find.text('21 sats'), findsOneWidget);
    // At most 3 addresses: the primary plus 2 others.
    expect(find.text('⚡ a@x.io'), findsOneWidget);
    expect(find.text('b@x.io'), findsOneWidget);
    expect(find.text('c@x.io'), findsOneWidget);
    expect(find.text('d@x.io'), findsNothing);

    await tester.tap(find.byKey(const Key('cards-recover')));
    await app.settle();
    expect(find.text('Print to recover your account'), findsOneWidget);
    expect(net.calls, contains('POST /api/cards/abc-1/recovery-tokens'));
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(find.text('Tap your card'), findsOneWidget);
  });

  test('the top-up QR is the owner\'s LNURL-pay', () {
    expect(lnurlpUri('a@x.io'),
        'lightning:${encodeLnurl('https://x.io/.well-known/lnurlp/a')}');
    expect(lnurlpUri('nope'), isNull);
  });

  testWidgets('top-up: LNURL and numpad tabs, paid when the balance rises',
      (tester) async {
    final net = FakeNet({
      'GET /api/cards/abc-1': (200, {'id': 'abc-1', 'username': 'a'}),
      'GET /api/cards/abc-1/owner': (200, owner),
    });
    pricing.seedRates(const Rates(0.05, 0.0001));
    final app = await pumpCards(tester, net);
    app.tap(cardUrl);
    await app.settle();
    // One frame starts an animation, the next runs it.
    Future<void> run() async {
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
    }

    await tester.tap(find.byKey(const Key('cards-topup')));
    await run();
    expect(find.byKey(const Key('topup-lnurl')), findsOneWidget);
    expect(find.text('a@x.io'), findsOneWidget);

    await tester.tap(find.byKey(const Key('topup-set-amount')));
    await run();
    // The cash register's currency switcher; type the amount in sats.
    await tester.tap(find.text('SAT'));
    await tester.pump();
    for (final d in ['1', '00']) {
      await tester.tap(find.text(d));
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(
        find.descendant(
            of: find.byKey(const Key('topup-charge')),
            matching: find.text('100 sats')),
        findsOneWidget);

    // Paid from any wallet: the owner's balance goes 21 → 121.
    net.routes['GET /api/cards/abc-1/owner'] =
        (200, {...owner, 'balanceSats': 121});
    await tester.pump(const Duration(seconds: 3));
    await app.settle();
    await run();
    expect(find.byKey(const Key('topup-done')), findsOneWidget);
    expect(find.text('+100 sats'), findsWidgets);
    expect(find.text('121 sats'), findsWidgets);
    expect(app.printed.single,
        {'amount': '100 sats', 'balance': '121 sats', 'address': 'a@x.io'});

    await tester.tap(find.byKey(const Key('topup-done')));
    await run();
    expect(find.text('Tap your card'), findsOneWidget);
  });

  group('top-up invoice', () {
    const topUpCard = CardDetail(
        id: 'abc-1', status: 'Activated', owned: true, disabled: false);
    final printed = <Map>[];
    late StreamController<String> taps;
    var done = false;

    setUp(() {
      printed.clear();
      nfcCalls.clear();
      done = false;
      taps = StreamController<String>.broadcast();
      pricing.seedRates(const Rates(0.05, 0.0001));
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(const MethodChannel('pos/printer'),
          (call) async {
        if (call.method == 'printCardTopUp') {
          printed.add(call.arguments as Map);
        }
        return call.method == 'isAvailable' ? true : 0;
      });
      messenger.setMockMethodCallHandler(const MethodChannel('pos/nfc'),
          (call) async {
        nfcCalls.add(call.method);
        return true;
      });
    });

    /// The top-up on its own, with [lnurl] for invoices and the owner's
    /// balance from [net]; returns a settle for Dio and a frame pump.
    Future<({Future<void> Function() settle, Future<void> Function() run})>
        pumpTopUp(WidgetTester tester, FakeLnurl lnurl,
            {int? balance = 21}) async {
      // Wider than the Z92: the test font draws every glyph a full em wide,
      // and the invoice's tap-to-pay hint would overflow where Roboto fits.
      tester.view
        ..physicalSize = const Size(1440, 2560)
        ..devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final net = FakeNet({
        'GET /api/cards/abc-1/owner': (200, {...owner, 'balanceSats': 21}),
      });
      await tester.pumpWidget(MaterialApp(
        theme: buildCardsTheme(),
        home: Scaffold(
          body: TopUpView(
            card: topUpCard,
            owner: OwnerSummary(
                owned: true,
                cardRecoveryEnabled: true,
                cardDisabled: false,
                balanceSats: balance),
            address: 'a@x.io',
            imageUrl: '',
            api: apiWith(net),
            taps: taps.stream,
            nfcAvailable: true,
            onDone: () => done = true,
            service: lnurl,
          ),
        ),
      ));
      Future<void> settle() async {
        for (var i = 0; i < 10; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump(const Duration(milliseconds: 1));
        }
      }

      Future<void> run() async {
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
      }

      await run();
      return (settle: settle, run: run);
    }

    /// Opens the amount tab and charges [sats] sats.
    Future<void> charge(
        WidgetTester tester, Future<void> Function() run, String digits) async {
      await tester.tap(find.byKey(const Key('topup-tab-1')));
      await run();
      await tester.tap(find.text('SAT'));
      await tester.pump();
      for (final d in digits.split('')) {
        await tester.tap(find.text(d).last);
        await tester.pump();
      }
      await tester.tap(find.byKey(const Key('topup-charge')));
      await run();
    }

    testWidgets(
        'the verify URL settles it; the slip never shows the old balance',
        (tester) async {
      final lnurl = FakeLnurl();
      final app = await pumpTopUp(tester, lnurl);
      await charge(tester, app.run, '500');
      expect(find.byType(InvoiceView), findsOneWidget);

      lnurl.settled = true;
      await tester.pump(const Duration(seconds: 2)); // verify poll
      await app.settle();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200)); // the burst
      }
      await app.run();
      expect(find.byKey(const Key('topup-done')), findsOneWidget);
      // The ledger still says 21: the slip adds what came in.
      expect(printed.single,
          {'amount': '500 sats', 'balance': '521 sats', 'address': 'a@x.io'});
      expect(nfcCalls, contains('vibrate'));

      await tester.tap(find.byKey(const Key('topup-done')));
      expect(done, isTrue);
    });

    testWidgets('Check event settles it on demand', (tester) async {
      final lnurl = FakeLnurl();
      final app = await pumpTopUp(tester, lnurl);
      await charge(tester, app.run, '5');
      lnurl.settled = true;
      final check = find.text('CHECK EVENT', findRichText: true);
      await tester.ensureVisible(check);
      await tester.pump();
      await tester.tap(check);
      await app.settle(); // ~10 ms: well before the 2 s verify poll
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('topup-done')), findsOneWidget);
      await app.run();
    });

    testWidgets('a tapped card pays the invoice', (tester) async {
      final lnurl = FakeLnurl();
      final app = await pumpTopUp(tester, lnurl);
      await charge(tester, app.run, '5');
      taps.add('lnurlw://x.io/api/cards/payer/scan?p=1&c=2');
      await tester.pump();
      expect(find.byType(NfcChargingView), findsOneWidget);
      expect(nfcCalls, contains('vibrate'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 500)); // settle polls
      }
      await app.settle();
      await app.run();
      expect(lnurl.cardsPaid, ['lnurlw://x.io/api/cards/payer/scan?p=1&c=2']);
      expect(find.byKey(const Key('topup-done')), findsOneWidget);
    });

    testWidgets('a declined card says why and the invoice keeps waiting',
        (tester) async {
      final app = await pumpTopUp(
          tester, FakeLnurl(decline: LnurlException('Card declined')));
      await charge(tester, app.run, '5');
      String? copied;
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      await tester.tap(find.byType(BakedQr)); // tapping the QR copies it
      expect(copied, 'lnbc5n1fake');

      taps.add('lnurlw://x.io/api/cards/payer/scan?p=1&c=2');
      await tester.pump();
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.text('Card declined'), findsOneWidget, reason: 'snackbar');
      expect(find.byType(InvoiceView), findsOneWidget);
      await tester.pump(const Duration(seconds: 5)); // the snackbar leaves
    });

    testWidgets('a failed invoice says why and goes back to the numpad',
        (tester) async {
      final app = await pumpTopUp(
          tester, FakeLnurl(fail: LnurlException('Monto mínimo: 10 sats')),
          balance: null);
      expect(find.text('—'), findsOneWidget, reason: 'no balance known');
      await charge(tester, app.run, '5');
      expect(find.textContaining('10 sats'), findsOneWidget);
      await tester.tap(find.text('Back'));
      await app.run();
      expect(find.byKey(const Key('topup-charge')), findsOneWidget);
    });

    testWidgets('an unexpected failure gets the generic message',
        (tester) async {
      final app =
          await pumpTopUp(tester, FakeLnurl(fail: StateError('socket')));
      await charge(tester, app.run, '5');
      expect(find.textContaining('invoice', findRichText: true), findsWidgets);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });
  });

  testWidgets('RECOVER says why it is off', (tester) async {
    final app = await pumpCards(
        tester,
        FakeNet({
          'GET /api/cards/abc-1': (200, {'id': 'abc-1', 'username': 'a'}),
          'GET /api/cards/abc-1/owner': (500, {'message': 'down'}),
        }));
    app.tap(cardUrl);
    await app.settle();
    expect(find.text('Balance unavailable'), findsOneWidget);
    expect(find.text('Owner info unavailable'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    // Typed by hand: no SUN proof, so recovery needs a real tap.
    final net = FakeNet({
      'GET /api/cards/abc-1': (200, {'id': 'abc-1', 'username': 'a'}),
      'GET /api/cards/abc-1/owner': (200, owner),
    });
    await tester.pumpWidget(const SizedBox());
    final manual = await pumpCards(tester, net);
    await tester.tap(find.text('Enter manually'));
    await tester.pump();
    await tester.enterText(
        find.byKey(const Key('cards-manual-field')), 'abc-1');
    await tester.pump();
    await tester.tap(find.byKey(const Key('cards-find')));
    await manual.settle();
    expect(find.text('Tap the card to recover'), findsOneWidget);
  });

  testWidgets('an unknown card fails and goes back', (tester) async {
    final app = await pumpCards(tester, FakeNet({}));
    await tester.tap(find.text('Enter manually'));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('cards-manual-field')), 'zzz');
    await tester.pump();
    await tester.tap(find.byKey(const Key('cards-find')));
    await app.settle();
    expect(find.text('Card not registered.'), findsOneWidget);
    await tester.tap(find.text('Back'));
    await tester.pump();
    expect(find.text('Tap your card'), findsOneWidget);
  });

  testWidgets('settings: session, auto-print and log out', (tester) async {
    final app = await pumpCards(tester, FakeNet({}));
    await tester.tap(find.byKey(const Key('cards-settings')));
    await tester.pump();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('beta.lawallet.io'), findsOneWidget);
    expect(find.text('Token expires'), findsOneWidget);

    await tester.tap(find.byKey(const Key('cards-autoprint')));
    await tester.pump();
    expect(CardsAuth.instance.autoPrint.value, isTrue);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.text('Tap your card'), findsOneWidget);

    await tester.tap(find.byKey(const Key('cards-settings')));
    await tester.pump();
    await tester.tap(find.text('Log out'));
    await app.settle();
    expect(find.text('Card activation'), findsOneWidget);
  });

  testWidgets('login: rejects bad tokens, accepts a good one', (tester) async {
    CardsAuth.instance.logout();
    final app = await pumpCards(tester, FakeNet({}));
    expect(find.text('Card activation'), findsOneWidget);

    await tester.tap(find.text('Paste token manually'));
    await tester.pump();
    final field = find.byKey(const Key('cards-token-field'));
    final use = find.byKey(const Key('cards-use-token'));

    await tester.enterText(field, 'not-a-token');
    await tester.pump();
    await tester.tap(use);
    await app.settle();
    expect(find.text("That QR isn't a valid device token."), findsOneWidget);

    await tester.enterText(field, jwt({'exp': 10}));
    await tester.pump();
    await tester.tap(use);
    await app.settle();
    expect(
        find.text('That token expired — ask for a new one.'), findsOneWidget);

    await tester.enterText(field, jwt({'exp': _future}));
    await tester.pump();
    await tester.tap(use);
    await app.settle();
    expect(find.text('Tap your card'), findsOneWidget);
  });

  testWidgets('the X leaves the miniapp', (tester) async {
    final app = await pumpCards(tester, FakeNet({}));
    await tester.tap(find.byKey(const Key('miniapp-close')));
    await app.settle();
    expect(find.text('hub'), findsOneWidget);
  });

  testWidgets('system back leaves the miniapp too', (tester) async {
    final app = await pumpCards(tester, FakeNet({}));
    await tester.binding.handlePopRoute();
    await app.settle();
    expect(find.text('hub'), findsOneWidget);
  });

  testWidgets('settings show the token\'s pubkey, scopes and kind',
      (tester) async {
    await CardsAuth.instance.login(jwt({
      'apiUrl': 'beta.lawallet.io',
      'exp': _future,
      'pubkey': '0123456789abcdef' * 4,
      'scopes': ['cards:read', 'cards:write'],
      'kind': 'DEVICE',
    }));
    await pumpCards(tester, FakeNet({}));
    await tester.tap(find.byKey(const Key('cards-settings')));
    await tester.pump();
    expect(find.text('0123456789ab…89abcdef'), findsOneWidget);
    expect(find.text('cards:read, cards:write'), findsOneWidget);
    expect(find.text('DEVICE'), findsOneWidget);
  });

  testWidgets('SCAN TOKEN: the X backs out, a scanned token logs in',
      (tester) async {
    final camera = FakeScanner();
    final real = MobileScannerPlatform.instance;
    MobileScannerPlatform.instance = camera;
    addTearDown(() => MobileScannerPlatform.instance = real);
    CardsAuth.instance.logout();
    final app = await pumpCards(tester, FakeNet({}));
    Future<void> openScanner() async {
      await tester.tap(find.byKey(const Key('cards-scan-token')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Scan the device token'), findsOneWidget);
    }

    await openScanner();
    await tester.tap(find.byIcon(Icons.close).last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(TokenScanPage), findsNothing);
    expect(find.text('Card activation'), findsOneWidget);

    await openScanner();
    final token = jwt({'apiUrl': 'beta.lawallet.io', 'exp': _future});
    camera.scans.add(BarcodeCapture(barcodes: [Barcode(rawValue: token)]));
    // A second read of the same QR must not pop twice.
    camera.scans.add(BarcodeCapture(barcodes: [Barcode(rawValue: token)]));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await app.settle();
    expect(find.text('Tap your card'), findsOneWidget);
  });

  testWidgets('locked, only the unlock leads out', (tester) async {
    addTearDown(() => lockedFlow.value = null);
    final app = await pumpCards(tester, FakeNet({}));
    await tester.tap(find.byKey(const Key('flow-lock')));
    await tester.pump();
    expect(find.byKey(const Key('miniapp-close')), findsNothing);
    await tester.tap(find.byKey(const Key('flow-unlock')));
    await app.settle();
    expect(find.text('home'), findsOneWidget, reason: 'no PIN, no address');
    expect(lockedFlow.value, isNull);
  });
}
