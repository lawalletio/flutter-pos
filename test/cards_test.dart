import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lawallet_pos/core/flow_lock.dart';
import 'package:lawallet_pos/features/cards/cards_api.dart';
import 'package:lawallet_pos/features/cards/cards_screen.dart';
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
      if (call.method == 'printCardQr') printed.add(call.arguments as Map);
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
