import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await CardsAuth.instance
        .login(jwt({'apiUrl': 'beta.lawallet.io/', 'exp': _future}));
  });

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
    final printed = <Map>[];
    messenger.setMockMethodCallHandler(const MethodChannel('pos/nfc'),
        (call) async => call.method == 'stopSession' ? null : true);
    messenger.setMockMethodCallHandler(const MethodChannel('pos/printer'),
        (call) async {
      if (call.method == 'printCardQr') printed.add(call.arguments as Map);
      return call.method == 'isAvailable' ? true : 0;
    });
    final net = FakeNet({
      'GET /api/cards/abc-1': (
        200,
        {
          'id': 'abc-1',
          'design': {'imageUrl': ''}
        }
      ),
      'POST /api/cards/abc-1/activation-tokens': (
        200,
        {'qrPayload': 'https://beta.lawallet.io/wallet/activate/abc-1?t=1'}
      ),
    });
    MockStreamHandlerEventSink? sink;
    messenger.setMockStreamHandler(const EventChannel('pos/nfc/tags'),
        MockStreamHandler.inline(onListen: (_, s) {
      sink = s;
    }));

    // Dio and the QR PNG need real async; the animations run on fake time.
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 1));
      }
    }

    tester.view
      ..physicalSize = const Size(720, 1440) // the Z92's portrait screen
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: CardsScreen(api: apiWith(net))));
    await tester.pump();
    await tester.pump();
    expect(find.text('Tap your card'), findsOneWidget);

    sink!.success(''); // a tag without a LaWallet lnurl
    await tester.pump();
    expect(find.text('Blank card'), findsOneWidget);
    await tester.tap(find.text('Back'));
    await tester.pump();

    sink!.success(cardUrl);
    await settle();
    expect(find.text('Not activated'), findsOneWidget);

    await tester.tap(find.byKey(const Key('cards-activate')));
    await settle();
    expect(find.text('Print to activate your card'), findsOneWidget);
    await settle();
    await tester.tap(find.byKey(const Key('cards-print')));
    await tester.pump();
    expect(find.text('Printing…'), findsOneWidget);
    await settle();
    await tester.pump(const Duration(milliseconds: 2100));
    expect(find.text('Tap your card'), findsOneWidget);
    expect(printed.single['subtitle'], 'Activate your card');
    expect(printed.single['caption'], 'beta.lawallet.io');
    expect(net.calls, contains('POST /api/cards/abc-1/activation-tokens'));
  });
}
