/// The WapuPay ramp-on API (sell sats for ARS, paid by bank transfer) and the
/// models it returns. Plain Dart plus Dio, with no Flutter import, so a screen
/// or a test can call [wapuErrorKey] from anywhere.
library;

import 'dart:convert';

import 'package:dio/dio.dart';

const kWapuDefaultBaseUrl = 'https://be-prod.wapu.app';

const _timeout = Duration(seconds: 15);

/// Creating and funding an order wait on the payment provider.
const _slowTimeout = Duration(seconds: 45);

const _direct = '/transactions/direct-fiat';

/// What every quote and order here asks for: sats over Lightning.
const _purchase = {
  'type': 'crypto_purchase',
  'payout_currency': 'SAT',
  'payout_network': 'LIGHTNING',
};

/// A failed call. [message] is the backend's `error` text, or a transport
/// description. [timeout] means the request may have reached the backend, so
/// its outcome is unknown.
class WapuApiException implements Exception {
  const WapuApiException(this.message, {this.statusCode, this.timeout = false});

  final String message;
  final int? statusCode;
  final bool timeout;

  @override
  String toString() => message;
}

/// The price of an order, before it is created.
class WapuQuote {
  const WapuQuote({
    required this.amountArsCents,
    required this.amountOut,
    required this.networkFeeOut,
    required this.totalAmountUsdt,
    required this.feeAmountUsdt,
    required this.minAmountArsCents,
    required this.liquidityOk,
  });

  factory WapuQuote.fromJson(Map<String, dynamic> j) => WapuQuote(
        amountArsCents: _int(j['amount_ars_cents']),
        amountOut: _int(j['amount_out']),
        networkFeeOut: _int(j['network_fee_out']),
        totalAmountUsdt: _int(j['total_amount_usdt']),
        feeAmountUsdt: _int(j['fee_amount_usdt']),
        minAmountArsCents: _int(j['min_amount_ars_cents']),
        liquidityOk: _flag(j['liquidity_ok']),
      );

  /// What the customer pays, in ARS cents.
  final int amountArsCents;

  /// What the customer receives, in sats.
  final int amountOut;

  /// The estimated Lightning fee, in sats.
  final int networkFeeOut;

  /// The total, and the part of it that is the fee, in USDT cents.
  final int totalAmountUsdt;
  final int feeAmountUsdt;

  /// The smallest order the backend takes, in ARS cents.
  final int minAmountArsCents;

  /// False when the backend cannot fill an order right now.
  final bool liquidityOk;

  /// The fee as a share of the total. It is already in the price.
  double get feePercent =>
      totalAmountUsdt <= 0 ? 0 : feeAmountUsdt * 100 / totalAmountUsdt;

  /// ARS per whole bitcoin at this quote.
  double get arsPerBtc =>
      amountOut <= 0 ? 0 : (amountArsCents / 100) / (amountOut / 1e8);
}

/// An order (the backend calls it a tentative).
class WapuOrder {
  const WapuOrder({
    required this.id,
    required this.status,
    required this.payoutStatus,
    required this.payoutAddress,
    required this.amountArsCents,
    required this.amountOut,
    required this.networkFeeOut,
    required this.watchPending,
    this.expiresAt,
    this.lateWatchUntil,
    this.alias,
    this.cvu,
    this.paymentHash,
    this.errorCode,
    this.type,
  });

  factory WapuOrder.fromJson(Map<String, dynamic> j) => WapuOrder(
        id: _text(j['tentative_id']),
        status: _text(j['status']),
        payoutStatus: _text(j['payout_status']),
        payoutAddress: _text(j['payout_address']),
        amountArsCents: _int(j['amount_ars_cents']),
        amountOut: _int(j['amount_out']),
        networkFeeOut: _int(j['network_fee_out']),
        watchPending: _flag(j['watch_pending']),
        expiresAt: _utc(j['expires_at']),
        lateWatchUntil: _utc(j['late_watch_until']),
        alias: _str(j['alias']),
        cvu: _str(j['cvu']),
        paymentHash: _str(j['payment_hash']),
        errorCode: _str(j['error_code']),
        type: _str(j['type']),
      );

  final String id;

  /// CREATED, FUNDING_ISSUED, EXPIRED, EXECUTED, COMPLETED or
  /// SETTLED_TO_BALANCE.
  final String status;
  final String payoutStatus;

  /// The customer's lightning address.
  final String payoutAddress;

  /// What the customer transfers, in ARS cents. Funding can raise it by up to
  /// 100 cents, so show this and never the quoted amount.
  final int amountArsCents;

  /// What the customer receives, in sats.
  final int amountOut;
  final int networkFeeOut;

  /// When the payment window closes.
  final DateTime? expiresAt;

  /// Until when a late transfer is still detected, after the window closed.
  final DateTime? lateWatchUntil;

  /// True while the backend still waits for, or acts on, a transfer.
  final bool watchPending;

  /// The bank alias and CVU to transfer to. Set once funding issued them.
  final String? alias;
  final String? cvu;

  /// Proof of the Lightning payment, once the sats were sent.
  final String? paymentHash;
  final String? errorCode;
  final String? type;

  bool get hasBankDetails => alias != null && cvu != null;

  /// Whether the order still needs attention at [now]: the backend watches it,
  /// or it was created and its window has not closed.
  bool isInProgress(DateTime now) =>
      watchPending ||
      (status == 'CREATED' && (expiresAt?.isAfter(now) ?? false));
}

/// The WapuPay API for one merchant key. [baseUrl] has no trailing slash. The
/// key and the timeouts go with each request, so an injected [dio] behaves
/// like the default one.
class WapuApi {
  WapuApi({required String baseUrl, required String apiKey, Dio? dio})
      : _baseUrl = baseUrl,
        _apiKey = apiKey,
        _dio = dio ?? Dio(BaseOptions(connectTimeout: _timeout));

  final String _baseUrl;
  final String _apiKey;
  final Dio _dio;

  /// Prices an order. Pass the ARS cents to spend or the sats to receive. A
  /// reply without `amount_out` or `liquidity_ok` is no quote, so it throws.
  Future<WapuQuote> quote({int? arsCents, int? sats}) async {
    final amount = _amount(arsCents, sats).map((k, v) => MapEntry(k, '$v'));
    final json =
        await _send('GET', '$_direct/quote', query: {..._purchase, ...amount});
    if (!json.containsKey('amount_out') || !json.containsKey('liquidity_ok')) {
      throw _unexpected;
    }
    return WapuQuote.fromJson(json);
  }

  /// Creates an order that pays [address]. It is not idempotent: after a
  /// timeout, or a reply with no order id, look in [orders] instead of calling
  /// this again.
  Future<WapuOrder> createOrder(
      {required String address, int? arsCents, int? sats}) async {
    return _singleOrder(
        await _send('POST', '$_direct/tentatives', slow: true, body: {
      ..._purchase,
      'payout_address': address,
      ..._amount(arsCents, sats),
    }));
  }

  /// Asks for the bank details of [orderId]. Repeating it returns the same
  /// order.
  Future<WapuOrder> fund(String orderId) async =>
      _singleOrder(await _send('POST', '${_tentative(orderId)}/funding',
          slow: true, body: const {}));

  /// Reads one order. A 404 means it is not this account's.
  Future<WapuOrder> order(String orderId) async =>
      _singleOrder(await _send('GET', _tentative(orderId)));

  /// The account's ARS to Lightning orders, in the order the API lists them.
  /// An entry with no id cannot be followed, so it is left out. A reply without
  /// the list throws: read as an empty history, it would say that no order was
  /// created.
  Future<List<WapuOrder>> orders() async {
    final all = (await _send('GET', '$_direct/tentatives'))['tentatives'];
    if (all is! List) throw _unexpected;
    return [
      for (final o in all)
        if (o is Map<String, dynamic>) WapuOrder.fromJson(o),
    ]
        .where((o) =>
            o.id.isNotEmpty && (o.type == null || o.type == 'crypto_purchase'))
        .toList();
  }

  /// Whether the account may buy: the backend's `beta_version` flag. A reply
  /// without it is not the WapuPay settings (a wrong URL that answers 200 with a
  /// web page, say), so it throws.
  Future<bool> betaEnabled() async {
    final settings = await _send('GET', '/users/user-settings');
    if (!settings.containsKey('beta_version')) throw _unexpected;
    return _flag(settings['beta_version']);
  }

  Future<void> setBeta(bool enabled) =>
      _send('PATCH', '/users/user-settings', body: {'beta_version': enabled});

  String _tentative(String id) =>
      '$_direct/tentatives/${Uri.encodeComponent(id)}';

  /// Sends one request and returns the JSON object it answers, or throws a
  /// [WapuApiException]. Only 2xx is success. The object is empty when the body
  /// is empty or not a JSON object, so a caller that needs a body checks it.
  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object>? body,
    bool slow = false,
  }) async {
    final Response<String> res;
    try {
      res = await _dio.request<String>(
        '$_baseUrl$path',
        queryParameters: query,
        data: body == null ? null : jsonEncode(body),
        options: Options(
          method: method,
          headers: {'X-API-Key': _apiKey},
          contentType: body == null ? null : Headers.jsonContentType,
          receiveTimeout: slow ? _slowTimeout : _timeout,
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );
    } on DioException catch (e) {
      throw switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout =>
          const WapuApiException('timeout', timeout: true),
        _ => WapuApiException(e.message ?? 'network error'),
      };
    }
    Map<String, dynamic> json = const {};
    try {
      final decoded = jsonDecode(res.data ?? '');
      if (decoded is Map<String, dynamic>) json = decoded;
    } on FormatException {
      // Empty or not JSON: the status code alone decides below.
    }
    final code = res.statusCode ?? 0;
    if (code < 200 || code >= 300) {
      throw WapuApiException(_str(json['error']) ?? 'HTTP $code',
          statusCode: code);
    }
    return json;
  }
}

/// How the screens get a client. A variable so a test can swap in a fake.
WapuApi Function(String baseUrl, String apiKey) wapuApiFor =
    (b, k) => WapuApi(baseUrl: b, apiKey: k);

/// The Spanish copy (a key of the i18n map) that tells the operator what went
/// wrong. Set [creating] for an order create. There, any failure that brought
/// no answer from the backend (a timeout or another transport error, so no
/// status code) or a server fault (5xx except 503, which the backend raises
/// before it creates anything) leaves it unknown whether the order exists. The
/// copy then sends the operator to the History instead of inviting a retry,
/// even when they are just offline.
String wapuErrorKey(WapuApiException e, {bool creating = false}) {
  final code = e.statusCode;
  final unknownOutcome =
      e.timeout || code == null || (code >= 500 && code != 503);
  if (creating && unknownOutcome) {
    return 'No sabemos si la orden se creó. Revisá el Historial antes de reintentar.';
  }
  if (e.timeout) return 'El servidor no respondió. Probá de nuevo.';
  final message = e.message.toLowerCase();
  return switch (code) {
    // Raised before anything is created, so it reads the same on a create.
    400 => 'La lightning address o el monto no son válidos',
    401 => 'La API key no es válida',
    403 when message.contains('beta') =>
      'Tu cuenta Wapu no tiene Beta features activado',
    403 when message.contains('disabled') =>
      'Las compras están deshabilitadas en Wapu',
    403 => 'Tu cuenta Wapu no puede comprar',
    404 => 'La orden no existe',
    409 => 'No hay liquidez disponible ahora. Probá en unos minutos.',
    422 => 'El monto está fuera de los límites',
    429 when message.contains('open') =>
      'Hay demasiadas órdenes abiertas. Esperá a que venzan.',
    429 when message.contains('monthly') =>
      'Se alcanzó el límite mensual de compras',
    429 => 'Demasiados intentos. Esperá un momento.',
    503 => 'El servicio no está disponible. Probá más tarde.',
    _ => 'No se pudo completar la operación',
  };
}

/// The failure for a 2xx reply that lacks what the call needs (an empty or
/// non-JSON body, say). It has no status code on purpose: on a create the order
/// may exist upstream, and [wapuErrorKey] then sends the operator to the
/// History.
const _unexpected = WapuApiException('unexpected response');

/// The order in the reply to a call that answers with one. Every such reply
/// carries the order's id, so one without it is [_unexpected].
WapuOrder _singleOrder(Map<String, dynamic> json) {
  final order = WapuOrder.fromJson(json);
  if (order.id.isEmpty) throw _unexpected;
  return order;
}

/// The one amount a request carries: ARS cents to spend, or sats to receive.
Map<String, int> _amount(int? arsCents, int? sats) {
  if ((arsCents == null) == (sats == null)) {
    throw ArgumentError('Pass exactly one of arsCents or sats');
  }
  return {
    if (arsCents != null) 'amount_ars_cents': arsCents,
    if (sats != null) 'amount_out': sats,
  };
}

String? _str(Object? v) {
  final s = v?.toString().trim();
  return s == null || s.isEmpty ? null : s;
}

String _text(Object? v) => _str(v) ?? '';

/// A whole number that may arrive as a decimal or as text. Missing is 0.
int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

bool _flag(Object? v) => v == true || v == 1;

/// The backend sends UTC. Text with no zone is UTC too, not local time.
DateTime? _utc(Object? v) {
  final s = _str(v);
  if (s == null) return null;
  final d = DateTime.tryParse(s);
  return d == null || d.isUtc ? d : DateTime.tryParse('${s}Z');
}
