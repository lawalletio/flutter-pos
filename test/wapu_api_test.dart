import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/core/i18n.dart';
import 'package:lawallet_pos/features/wapu/wapu_api.dart';

/// Answers each request with [routes]`[METHOD path]` → (status, body), and
/// records it. A [String] body goes out as is, anything else as JSON. A route
/// in [failures] throws its [DioException] instead.
class FakeNet implements HttpClientAdapter {
  FakeNet(this.routes, {this.failures = const {}});
  final Map<String, (int, Object)> routes;
  final Map<String, DioException> failures;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
      RequestOptions o, Stream<Uint8List>? _, Future<void>? __) async {
    requests.add(o);
    final key = '${o.method} ${o.uri.path}';
    final failure = failures[key];
    if (failure != null) throw failure;
    final (code, body) = routes[key] ?? (404, {'error': 'nope'});
    return ResponseBody.fromString(
        body is String ? body : jsonEncode(body), code,
        headers: {
          'content-type': ['application/json']
        });
  }

  @override
  void close({bool force = false}) {}
}

WapuApi apiWith(FakeNet net) => WapuApi(
    baseUrl: 'https://wapu.test',
    apiKey: 'k',
    dio: Dio()..httpClientAdapter = net);

/// A quote for 15,000 ARS against 10,000 sats, with a 2.5% fee.
Map<String, Object?> quoteJson([Map<String, Object?> over = const {}]) => {
      'amount_ars_cents': 1500000,
      'amount_out': 10000,
      'amount_out_unit': 'sats',
      'network_fee_out': 3,
      'total_amount_usdt': 1000,
      'fee_amount_usdt': 25,
      'funding_amount_usdt': 1000,
      'min_amount_ars_cents': 1000000,
      'expiration_minutes': 15,
      'liquidity_ok': true,
      ...over,
    };

/// A freshly created order: no bank details yet.
Map<String, Object?> orderJson([Map<String, Object?> over = const {}]) => {
      'tentative_id': 't1',
      'type': 'crypto_purchase',
      'status': 'CREATED',
      'payout_status': 'waiting_ars',
      'payout_currency': 'SAT',
      'payout_network': 'LIGHTNING',
      'payout_address': 'alice@example.com',
      'amount_ars_cents': 1500000,
      'amount_out': 10000,
      'amount_out_unit': 'sats',
      'network_fee_out': 3,
      'total_amount_usdt': 1000,
      'fee_amount_usdt': 25,
      'funding_amount_usdt': 1000,
      'expires_at': '2026-10-29T15:00:00Z',
      'late_watch_until': null,
      'watch_pending': false,
      'txid': null,
      'payment_hash': null,
      'error_code': null,
      ...over,
    };

/// The [WapuApiException] that [call] fails with.
Future<WapuApiException> failure(Future<Object?> call) async {
  try {
    await call;
  } on WapuApiException catch (e) {
    return e;
  }
  fail('expected a WapuApiException');
}

DioException dioFailure(DioExceptionType type, {String? message}) =>
    DioException(
        requestOptions: RequestOptions(), type: type, message: message);

const timedOut = WapuApiException('timeout', timeout: true);

WapuApiException http(int code, [String message = '']) =>
    WapuApiException(message, statusCode: code);

/// Each row of the copy table: what happened, the error, whether it was an
/// order create, the Spanish key and its English text.
final copy = <(String, WapuApiException, bool, String, String)>[
  (
    'timeout while creating',
    timedOut,
    true,
    'No sabemos si la orden se creó. Revisá el Historial antes de reintentar.',
    "We don't know if the order was created. Check the History before retrying.",
  ),
  (
    'timeout',
    timedOut,
    false,
    'El servidor no respondió. Probá de nuevo.',
    'The server did not respond. Try again.',
  ),
  (
    '401',
    http(401, 'invalid key'),
    false,
    'La API key no es válida',
    'The API key is not valid',
  ),
  (
    '403 beta',
    http(403, 'require beta access'),
    false,
    'Tu cuenta Wapu no tiene Beta features activado',
    'Your Wapu account does not have Beta features on',
  ),
  (
    '403 beta, any case',
    http(403, 'Require BETA Access'),
    false,
    'Tu cuenta Wapu no tiene Beta features activado',
    'Your Wapu account does not have Beta features on',
  ),
  (
    '403 disabled',
    http(403, 'crypto purchases are disabled'),
    false,
    'Las compras están deshabilitadas en Wapu',
    'Purchases are disabled in Wapu',
  ),
  (
    '403 other',
    http(403, 'an active registered user is required'),
    false,
    'Tu cuenta Wapu no puede comprar',
    'Your Wapu account cannot buy',
  ),
  (
    '404',
    http(404, 'not found'),
    false,
    'La orden no existe',
    'The order does not exist',
  ),
  (
    '409',
    http(409, 'no receiver'),
    false,
    'No hay liquidez disponible ahora. Probá en unos minutos.',
    'No liquidity available right now. Try again in a few minutes.',
  ),
  (
    '409 while creating',
    http(409, 'busy'),
    true,
    'No hay liquidez disponible ahora. Probá en unos minutos.',
    'No liquidity available right now. Try again in a few minutes.',
  ),
  (
    '422',
    http(422, 'amount too small for the fee'),
    false,
    'El monto está fuera de los límites',
    'The amount is out of range',
  ),
  (
    '429 open',
    http(429, 'too many open purchase orders'),
    false,
    'Hay demasiadas órdenes abiertas. Esperá a que venzan.',
    'There are too many open orders. Wait for them to expire.',
  ),
  (
    '429 monthly',
    http(429, 'monthly purchase limit reached'),
    false,
    'Se alcanzó el límite mensual de compras',
    'The monthly purchase limit was reached',
  ),
  (
    '429 other',
    http(429, 'too many purchase orders'),
    false,
    'Demasiados intentos. Esperá un momento.',
    'Too many attempts. Wait a moment.',
  ),
  (
    '503',
    http(503, 'lightning address unreachable'),
    false,
    'El servicio no está disponible. Probá más tarde.',
    'The service is unavailable. Try again later.',
  ),
  (
    'unknown status',
    http(500, 'boom'),
    false,
    'No se pudo completar la operación',
    'The operation could not be completed',
  ),
  (
    'no status at all',
    const WapuApiException('offline'),
    false,
    'No se pudo completar la operación',
    'The operation could not be completed',
  ),
];

void main() {
  test('quote by sats sends only the API key and amount_out', () async {
    final net = FakeNet({
      'GET /transactions/direct-fiat/quote': (200, quoteJson()),
    });

    final q = await apiWith(net).quote(sats: 100);

    final r = net.requests.single;
    expect(r.method, 'GET');
    expect(r.uri.origin, 'https://wapu.test');
    expect(r.uri.path, endsWith('/transactions/direct-fiat/quote'));
    expect(r.queryParameters, {
      'type': 'crypto_purchase',
      'payout_currency': 'SAT',
      'payout_network': 'LIGHTNING',
      'amount_out': '100',
    });
    expect(r.headers['X-API-Key'], 'k');
    expect(r.headers['Authorization'], isNull);
    expect(r.headers.keys.map((h) => h.toLowerCase()), ['x-api-key']);
    expect(r.receiveTimeout, const Duration(seconds: 15));
    expect(q.amountArsCents, 1500000);
    expect(q.amountOut, 10000);
    expect(q.networkFeeOut, 3);
    expect(q.totalAmountUsdt, 1000);
    expect(q.feeAmountUsdt, 25);
    expect(q.minAmountArsCents, 1000000);
    expect(q.liquidityOk, isTrue);
  });

  test('quote by ARS sends amount_ars_cents', () async {
    final net = FakeNet({
      'GET /transactions/direct-fiat/quote': (
        200,
        quoteJson({'liquidity_ok': false})
      ),
    });

    final q = await apiWith(net).quote(arsCents: 1500000);

    expect(net.requests.single.queryParameters, {
      'type': 'crypto_purchase',
      'payout_currency': 'SAT',
      'payout_network': 'LIGHTNING',
      'amount_ars_cents': '1500000',
    });
    expect(q.liquidityOk, isFalse);
  });

  test('quote needs exactly one amount', () async {
    final net = FakeNet({});
    final api = apiWith(net);

    await expectLater(api.quote(), throwsArgumentError);
    await expectLater(api.quote(arsCents: 1, sats: 1), throwsArgumentError);
    expect(net.requests, isEmpty);
  });

  test('quote derives the fee percent and the effective rate', () {
    final q = WapuQuote.fromJson(quoteJson());

    // 25 of 1000 USDT cents; 15,000 ARS for 0.0001 BTC.
    expect(q.feePercent, 2.5);
    expect(q.arsPerBtc, closeTo(150000000, 1));
  });

  test('a quote with nothing in it has no fee, no rate and no liquidity', () {
    final q = WapuQuote.fromJson({});

    expect(q.feePercent, 0);
    expect(q.arsPerBtc, 0);
    expect(q.liquidityOk, isFalse);
  });

  test('amounts may arrive as strings or decimals', () {
    final q = WapuQuote.fromJson(
        quoteJson({'amount_ars_cents': 1500000.0, 'amount_out': '10000'}));

    expect(q.amountArsCents, 1500000);
    expect(q.amountOut, 10000);
  });

  test('createOrder posts integer amounts', () async {
    final net = FakeNet({
      'POST /transactions/direct-fiat/tentatives': (201, orderJson()),
    });

    final o = await apiWith(net)
        .createOrder(address: 'alice@example.com', arsCents: 1500000);

    final r = net.requests.single;
    expect(r.uri.path, endsWith('/transactions/direct-fiat/tentatives'));
    expect(jsonDecode(r.data as String), {
      'type': 'crypto_purchase',
      'payout_currency': 'SAT',
      'payout_network': 'LIGHTNING',
      'payout_address': 'alice@example.com',
      'amount_ars_cents': 1500000,
    });
    expect(r.contentType, contains('application/json'));
    expect(r.headers['X-API-Key'], 'k');
    expect(r.headers['Authorization'], isNull);
    expect(r.receiveTimeout, const Duration(seconds: 45));
    expect(o.id, 't1');
    expect(o.status, 'CREATED');
    expect(o.hasBankDetails, isFalse);
  });

  test('createOrder by sats posts amount_out', () async {
    final net = FakeNet({
      'POST /transactions/direct-fiat/tentatives': (201, orderJson()),
    });

    await apiWith(net).createOrder(address: 'alice@example.com', sats: 10000);

    expect(jsonDecode(net.requests.single.data as String), {
      'type': 'crypto_purchase',
      'payout_currency': 'SAT',
      'payout_network': 'LIGHTNING',
      'payout_address': 'alice@example.com',
      'amount_out': 10000,
    });
  });

  test('createOrder needs exactly one amount and sends nothing otherwise',
      () async {
    final net = FakeNet({});
    final api = apiWith(net);

    await expectLater(
        api.createOrder(address: 'alice@example.com'), throwsArgumentError);
    await expectLater(
        api.createOrder(address: 'alice@example.com', arsCents: 1, sats: 1),
        throwsArgumentError);
    expect(net.requests, isEmpty);
  });

  test('fund posts {} and parses bank details', () async {
    final net = FakeNet({
      'POST /transactions/direct-fiat/tentatives/t1/funding': (
        201,
        orderJson({
          'status': 'FUNDING_ISSUED',
          'amount_ars_cents': 1500037,
          'watch_pending': true,
          'alias': 'wapu.pagos',
          'cvu': '0000003100000000000001',
        })
      ),
    });

    final o = await apiWith(net).fund('t1');

    final r = net.requests.single;
    expect(r.uri.path, endsWith('/tentatives/t1/funding'));
    expect(r.data, '{}');
    expect(r.contentType, contains('application/json'));
    expect(r.receiveTimeout, const Duration(seconds: 45));
    expect(o.alias, 'wapu.pagos');
    expect(o.cvu, '0000003100000000000001');
    expect(o.amountArsCents, 1500037);
    expect(o.watchPending, isTrue);
    expect(o.hasBankDetails, isTrue);
  });

  // Dio implies a JSON content type for a string body, but only through a
  // default interceptor that a Dio can drop. The request must not depend on it.
  test('the JSON content type does not depend on Dio defaults', () async {
    final net = FakeNet({
      'POST /transactions/direct-fiat/tentatives/t1/funding': (
        201,
        orderJson()
      ),
    });
    final api = WapuApi(
        baseUrl: 'https://wapu.test',
        apiKey: 'k',
        dio: Dio()
          ..interceptors.removeImplyContentTypeInterceptor()
          ..httpClientAdapter = net);

    await api.fund('t1');

    expect(net.requests.single.contentType, contains('application/json'));
  });

  test('order fetches one tentative and escapes its id', () async {
    final net = FakeNet({
      'GET /transactions/direct-fiat/tentatives/t1': (200, orderJson()),
      'GET /transactions/direct-fiat/tentatives/a%2Fb': (
        200,
        orderJson({'tentative_id': 'a/b'})
      ),
    });
    final api = apiWith(net);

    expect((await api.order('t1')).id, 't1');
    expect((await api.order('a/b')).id, 'a/b');
    expect(net.requests.map((r) => r.receiveTimeout),
        everyElement(const Duration(seconds: 15)));
  });

  test('an order parses every field it carries', () {
    final o = WapuOrder.fromJson(orderJson({
      'tentative_id': 42,
      'status': 'COMPLETED',
      'payout_status': 'completed',
      'watch_pending': false,
      'payment_hash': 'abc123',
      'error_code': 'E1',
      'alias': 'wapu.pagos',
      'cvu': '0000003100000000000001',
    }));

    expect(o.id, '42');
    expect(o.type, 'crypto_purchase');
    expect(o.status, 'COMPLETED');
    expect(o.payoutStatus, 'completed');
    expect(o.payoutAddress, 'alice@example.com');
    expect(o.amountArsCents, 1500000);
    expect(o.amountOut, 10000);
    expect(o.networkFeeOut, 3);
    expect(o.paymentHash, 'abc123');
    expect(o.errorCode, 'E1');
  });

  test('bank details need both an alias and a cvu, and blank is absent', () {
    bool has(Map<String, Object?> over) =>
        WapuOrder.fromJson(orderJson(over)).hasBankDetails;

    expect(
        has({'alias': 'wapu.pagos', 'cvu': '0000003100000000000001'}), isTrue);
    expect(has({'alias': 'wapu.pagos'}), isFalse);
    expect(has({'cvu': '0000003100000000000001'}), isFalse);
    expect(has({'alias': '', 'cvu': ' '}), isFalse);
    expect(WapuOrder.fromJson(orderJson({'alias': ''})).alias, isNull);
  });

  test('orders keeps only crypto purchases', () async {
    final net = FakeNet({
      'GET /transactions/direct-fiat/tentatives': (
        200,
        {
          'tentatives': [
            orderJson({'tentative_id': 'a'}),
            orderJson({'tentative_id': 'b', 'type': 'crypto_sale'}),
          ],
        }
      ),
    });

    final list = await apiWith(net).orders();

    expect(list, hasLength(1));
    expect(list.single.id, 'a');
    expect(net.requests.single.method, 'GET');
  });

  test('orders keeps an order that carries no type, in the API order',
      () async {
    final net = FakeNet({
      'GET /transactions/direct-fiat/tentatives': (
        200,
        {
          'tentatives': [
            orderJson({'tentative_id': 'a'}),
            orderJson({'tentative_id': 'b'})..remove('type'),
            orderJson({'tentative_id': 'c', 'type': 'crypto_sale'}),
            orderJson({'tentative_id': 'd'}),
          ],
        }
      ),
    });

    final list = await apiWith(net).orders();

    expect(list.map((o) => o.id), ['a', 'b', 'd']);
  });

  test('orders is empty when the list is missing', () async {
    final net = FakeNet({
      'GET /transactions/direct-fiat/tentatives': (200, {}),
    });

    expect(await apiWith(net).orders(), isEmpty);
  });

  test('parses timestamps as UTC', () {
    final o = WapuOrder.fromJson(orderJson(
        {'expires_at': '2026-10-29T15:00:00Z', 'late_watch_until': null}));

    expect(o.expiresAt, DateTime.utc(2026, 10, 29, 15));
    expect(o.lateWatchUntil, isNull);

    // Text with no zone is still UTC; an offset is converted; junk is no time.
    for (final (raw, want) in [
      ('2026-10-29T15:00:00', DateTime.utc(2026, 10, 29, 15)),
      ('2026-10-29T12:00:00-03:00', DateTime.utc(2026, 10, 29, 15)),
      ('soon', null),
    ]) {
      final parsed = WapuOrder.fromJson(orderJson({'late_watch_until': raw}))
          .lateWatchUntil;
      expect(parsed, want, reason: raw);
    }
  });

  test('errors carry backend message and status', () async {
    final net = FakeNet({
      'POST /transactions/direct-fiat/tentatives': (
        429,
        {'error': 'too many open purchase orders'}
      ),
    });

    final e = await failure(apiWith(net)
        .createOrder(address: 'alice@example.com', arsCents: 1500000));

    expect(e.statusCode, 429);
    expect(e.message, 'too many open purchase orders');
    expect(e.timeout, isFalse);
    expect(wapuErrorKey(e),
        'Hay demasiadas órdenes abiertas. Esperá a que venzan.');
  });

  test('a failure without a backend message falls back to the HTTP status',
      () async {
    // A non-2xx reply is a failure even when it is not a 4xx or 5xx.
    for (final (code, body) in <(int, Object)>[
      (502, '<html>Bad Gateway</html>'),
      (500, ''),
      (404, <String, Object?>{}),
      (400, {'error': ''}),
      (302, <String, Object?>{}),
    ]) {
      final net = FakeNet({'GET /users/user-settings': (code, body)});

      final e = await failure(apiWith(net).betaEnabled());

      expect(e.message, 'HTTP $code');
      expect(e.statusCode, code);
      expect(e.timeout, isFalse);
    }
  });

  test('a receive timeout is an unknown outcome', () async {
    final net = FakeNet({}, failures: {
      'POST /transactions/direct-fiat/tentatives':
          dioFailure(DioExceptionType.receiveTimeout),
    });

    final e = await failure(apiWith(net)
        .createOrder(address: 'alice@example.com', arsCents: 1500000));

    expect(e.timeout, isTrue);
    expect(e.statusCode, isNull);
    expect(wapuErrorKey(e, creating: true),
        'No sabemos si la orden se creó. Revisá el Historial antes de reintentar.');
    // A create is never retried on its own.
    expect(net.requests, hasLength(1));
  });

  test('connection and send timeouts are timeouts too', () async {
    for (final type in [
      DioExceptionType.connectionTimeout,
      DioExceptionType.sendTimeout,
    ]) {
      final net =
          FakeNet({}, failures: {'GET /users/user-settings': dioFailure(type)});

      final e = await failure(apiWith(net).betaEnabled());

      expect(e.timeout, isTrue, reason: '$type');
    }
  });

  test('any other network error keeps its message and is not a timeout',
      () async {
    final net = FakeNet({}, failures: {
      'GET /users/user-settings':
          dioFailure(DioExceptionType.connectionError, message: 'offline'),
      'PATCH /users/user-settings': dioFailure(DioExceptionType.unknown),
    });
    final api = apiWith(net);

    final offline = await failure(api.betaEnabled());
    expect(offline.message, 'offline');
    expect(offline.timeout, isFalse);
    expect(offline.statusCode, isNull);

    expect((await failure(api.setBeta(true))).message, 'network error');
  });

  test('beta read and write', () async {
    final net = FakeNet({
      'GET /users/user-settings': (
        200,
        {'language': 'es', 'beta_version': true, 'favorite_currency': 'ARS'}
      ),
      'PATCH /users/user-settings': (200, {}),
    });
    final api = apiWith(net);

    expect(await api.betaEnabled(), isTrue);
    await api.setBeta(false);

    final patch = net.requests.last;
    expect(patch.method, 'PATCH');
    expect(patch.uri.path, endsWith('/users/user-settings'));
    expect(jsonDecode(patch.data as String), {'beta_version': false});
    expect(patch.contentType, contains('application/json'));
    expect(patch.headers['X-API-Key'], 'k');
  });

  test('beta is on for true or 1 and off for anything else', () async {
    for (final (value, want) in <(Object?, bool)>[
      (true, true),
      (1, true),
      (false, false),
      (0, false),
      (null, false),
    ]) {
      final net = FakeNet({
        'GET /users/user-settings': (200, {'beta_version': value}),
      });

      expect(await apiWith(net).betaEnabled(), want, reason: '$value');
    }
  });

  test('isInProgress', () {
    final now = DateTime.utc(2026, 10, 29, 14);
    bool inProgress(Map<String, Object?> over) =>
        WapuOrder.fromJson(orderJson(over)).isInProgress(now);

    // Waiting for bank details until it expires.
    expect(
        inProgress({'status': 'CREATED', 'expires_at': '2026-10-29T14:05:00Z'}),
        isTrue);
    expect(
        inProgress({'status': 'CREATED', 'expires_at': '2026-10-29T13:55:00Z'}),
        isFalse);
    expect(
        inProgress({'status': 'CREATED', 'expires_at': '2026-10-29T14:00:00Z'}),
        isFalse);
    expect(inProgress({'status': 'CREATED', 'expires_at': null}), isFalse);
    // The backend is still watching for a transfer.
    expect(inProgress({'status': 'EXPIRED', 'watch_pending': true}), isTrue);
    expect(inProgress({'status': 'EXPIRED', 'watch_pending': false}), isFalse);
    expect(inProgress({'status': 'COMPLETED'}), isFalse);
  });

  test('wapuErrorKey maps 401, 403-beta, 409, 503 and unknown', () {
    for (final (what, error, creating, key, _) in copy) {
      expect(wapuErrorKey(error, creating: creating), key, reason: what);
    }
  });

  test('on create, a server fault is an unknown outcome but 503 is not', () {
    const unknown =
        'No sabemos si la orden se creó. Revisá el Historial antes de reintentar.';

    for (final code in [500, 502, 504]) {
      expect(
          wapuErrorKey(http(code, 'upstream failed'), creating: true), unknown,
          reason: '$code');
    }
    // The backend raises 503 before it creates anything.
    expect(
        wapuErrorKey(http(503, 'lightning address unreachable'),
            creating: true),
        'El servicio no está disponible. Probá más tarde.');
    // A refusal below 500 created nothing either.
    expect(
        wapuErrorKey(http(422, 'amount too small for the fee'), creating: true),
        'El monto está fuera de los límites');
    // Off a create, a server fault is just a failure.
    expect(wapuErrorKey(http(500, 'upstream failed')),
        'No se pudo completar la operación');
  });

  test('on create, a failure with no status is an unknown outcome too', () {
    const unknown =
        'No sabemos si la orden se creó. Revisá el Historial antes de reintentar.';

    // Whatever its text: the request may have been sent before the link broke.
    for (final message in [
      'network error',
      'offline',
      'The connection errored: Connection closed before full header was received',
    ]) {
      expect(wapuErrorKey(WapuApiException(message), creating: true), unknown,
          reason: message);
    }
    // Off a create there is nothing to duplicate, so it is just a failure.
    expect(wapuErrorKey(const WapuApiException('network error')),
        'No se pudo completar la operación');
  });

  test('every error key has an English entry', () {
    final en = AppLocalizations(AppLanguage.en);

    for (final (what, _, _, key, english) in copy) {
      expect(en.tr(key), english, reason: what);
    }
  });
}
