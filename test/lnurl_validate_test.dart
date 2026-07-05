import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/data/lnurl/lnurl_service.dart';

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
}
