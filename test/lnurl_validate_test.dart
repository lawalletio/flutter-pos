import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/data/lnurl/lnurl_service.dart';
import 'package:lawallet_pos/data/nostr/identity.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A Dio adapter that returns the same canned response for any request.
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.body, {this.status = 200});
  final String body;
  final int status;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return ResponseBody.fromString(body, status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

/// Serves the lnurlp body, then [invoiceBody] for the callback, and records
/// every URL asked for.
class _RoutedAdapter implements HttpClientAdapter {
  _RoutedAdapter(this.lnurlp, this.invoiceBody);
  final String lnurlp;
  final String invoiceBody;
  final List<Uri> seen = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    seen.add(options.uri);
    final body =
        options.uri.path.contains('.well-known') ? lnurlp : invoiceBody;
    return ResponseBody.fromString(body, 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

LnurlService _serviceReturning(String body, {int status = 200}) =>
    LnurlService(dio: Dio()..httpClientAdapter = _CannedAdapter(body, status: status));

void main() {
  // The real lawallet.io lnurlp: a valid payRequest with NO allowsNostr and NO
  // nostrPubkey (and a callback that may be momentarily 503). It must still be
  // accepted — requiring a LUD-21/NIP-57 confirmation mechanism up front
  // wrongly rejected `agustin@lawallet.io`.
  const lawalletBody = '{"status":"OK","tag":"payRequest",'
      '"callback":"https://beta.lawallet.io/api/lud16/agustin/cb",'
      '"minSendable":1000,"maxSendable":1000000000,"commentAllowed":200}';

  test('validate accepts a resolvable payRequest without LUD-21/NIP-57',
      () async {
    final svc = _serviceReturning(lawalletBody);
    await expectLater(svc.validate('agustin@lawallet.io'), completes);
  });

  test('validate rejects a response that is not a payRequest', () async {
    final svc = _serviceReturning('{"status":"ERROR","reason":"not found"}');
    await expectLater(
        svc.validate('nobody@example.com'), throwsA(isA<LnurlException>()));
  });

  // Live walletofsatoshi.com responses (2026-11): allowsNostr, but the
  // invoice has no LUD-21 `verify`, and its NIP-05 has no entry for the user,
  // so there is no merchant pubkey. The zap receipt is the only way to see
  // the payment, so a zap request must go out anyway.
  test('a Wallet of Satoshi invoice is watched by zap receipt', () async {
    SharedPreferences.setMockInitialValues({});
    const wosKey =
        'be1d89794bf92de5dd64c1e60f6a2c70c140abac9932418fee30c5c637fe9479';
    final adapter = _RoutedAdapter(
      '{"callback":"https://livingroomofsatoshi.com/api/v1/lnurl/payreq/x",'
          '"maxSendable":100000000000,"minSendable":1000,"metadata":"[]",'
          '"tag":"payRequest","allowsNostr":true,"nostrPubkey":"$wosKey"}',
      '{"pr":"lnbc10n1wos","routes":[]}',
    );
    final svc = LnurlService(dio: Dio()..httpClientAdapter = adapter);

    final inv = await svc.requestInvoice('test@walletofsatoshi.com', 1,
        relays: const ['wss://relay.damus.io']);

    expect(inv.verify, isNull);
    expect(inv.zapEnabled, isTrue);
    expect(inv.zapPubkey, wosKey);
    final zap = jsonDecode(adapter.seen.last.queryParameters['nostr']!) as Map;
    final p = [for (final t in zap['tags'] as List) if (t[0] == 'p') t[1]];
    // The till's own key, never the provider's shared one.
    expect(p, [await nostrIdentity.publicKey()]);
    expect(p, isNot(contains(wosKey)));
  });

  test('a merchant with their own NIP-05 key is still the zap recipient',
      () async {
    const merchant =
        '2ad91f1dca2dcd5fc89e7208d1e5059f0bac0870d63fc3bac21c7a9388fa18fd';
    final adapter = _RoutedAdapter(
      '{"callback":"https://getalby.com/lnurlp/x/callback",'
          '"minSendable":1000,"maxSendable":10000000000,"tag":"payRequest",'
          '"allowsNostr":true,"nostrPubkey":"79f00d3f5a19ec806189fcab03c1be4ff81d18ee4f653c88fac41fe03570f432"}',
      '{"pr":"lnbc10n1alby","verify":"https://getalby.com/v"}',
    );
    final svc = LnurlService(dio: Dio()..httpClientAdapter = adapter);

    await svc.requestInvoice('barra@lacrypta.ar', 1,
        relays: const ['wss://relay.lacrypta.ar'], recipientPubkey: merchant);

    final zap = jsonDecode(adapter.seen.last.queryParameters['nostr']!) as Map;
    expect([for (final t in zap['tags'] as List) if (t[0] == 'p') t[1]],
        [merchant]);
  });
}
