import 'dart:async';
import 'dart:io' show SocketException;

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/data/lnurl/lnurl_service.dart';
import 'package:lawallet_pos/features/payment/card_charge.dart';

/// Answers the card's withdrawRequest, its callback and the LUD-21 verify URL.
/// The invoice reads settled once an OK callback has paid it.
class _CardNet implements HttpClientAdapter {
  _CardNet(
      {this.callback = '{"status":"OK"}', this.answer, this.failPolls = 0});
  final String callback;

  /// The card server pays at once but holds its reply until this completes.
  final Future<void>? answer;

  /// Verify polls that fail before one gets through.
  int failPolls;
  final paidInvoices = <String>[];
  var _settled = false;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final uri = options.uri;
    final String body;
    switch (uri.path) {
      case '/card':
        body = '{"tag":"withdrawRequest","callback":"https://card.test/cb",'
            '"k1":"k"}';
      case '/cb':
        paidInvoices.add(uri.queryParameters['pr']!);
        _settled = !callback.contains('ERROR');
        await answer;
        body = callback;
      default:
        if (failPolls > 0) {
          failPolls--;
          throw const SocketException('verify down');
        }
        body = '{"status":"OK","settled":$_settled}';
    }
    return ResponseBody.fromString(body, 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final nfcCalls = <String>[];

  setUp(() {
    nfcCalls.clear();
    messenger.setMockMethodCallHandler(const MethodChannel('pos/nfc'),
        (call) async {
      nfcCalls.add(call.method);
      return call.method == 'stopSession' ? null : true;
    });
  });

  /// Delivers [cardUrl] on the tag stream once the reader is listening.
  void tapCard(String cardUrl) {
    messenger.setMockStreamHandler(
      const EventChannel('pos/nfc/tags'),
      MockStreamHandler.inline(onListen: (_, sink) => sink.success(cardUrl)),
    );
  }

  /// Long enough for a couple of verify polls.
  Future<void> settle() => Future<void>.delayed(const Duration(seconds: 1));

  ({CardCharge card, List<String> events}) charge(_CardNet net,
      {bool canTap = true}) {
    final events = <String>[];
    late final CardCharge card;
    card = CardCharge(
      invoice: () => 'lnbc1invoice',
      verifyUrl: () => 'https://provider.test/verify',
      waiting: () => true,
      canTap: () => canTap,
      onChange: () => events.add(card.collecting ? 'collecting' : 'idle'),
      onPaid: () => events.add('paid'),
      onPending: () => events.add('pending'),
      onError: (m) => events.add('error: $m'),
      service: LnurlService(dio: Dio()..httpClientAdapter = net),
    );
    return (card: card, events: events);
  }

  test('a tapped card pays the invoice on screen and settles', () async {
    final net = _CardNet();
    tapCard('lnurlw://card.test/card');
    final c = charge(net);
    await c.card.arm();
    await settle();

    expect(c.card.available, isTrue);
    expect(net.paidInvoices, ['lnbc1invoice']);
    expect(c.events, ['idle', 'collecting', 'paid']);
    expect(nfcCalls, contains('vibrate'));
    expect(c.card.collecting, isFalse);
    c.card.stop();
  });

  test('a rejected card reports the reason and goes back to waiting', () async {
    final net = _CardNet(callback: '{"status":"ERROR","reason":"Sin saldo"}');
    tapCard('lnurlw://card.test/card');
    final c = charge(net);
    await c.card.arm();
    await settle();

    expect(c.events, ['idle', 'collecting', 'idle', 'error: Sin saldo']);
    expect(c.card.collecting, isFalse);
    c.card.stop();
  });

  test('a tap is ignored while the screen says no', () async {
    final net = _CardNet();
    tapCard('lnurlw://card.test/card');
    final c = charge(net, canTap: false);
    await c.card.arm();
    await pumpEventQueue();

    expect(net.paidInvoices, isEmpty);
    expect(c.events, ['idle']);
    expect(nfcCalls, isNot(contains('vibrate')));
    c.card.stop();
  });

  test('settles off the verify URL before the card server answers', () async {
    final reply = Completer<void>();
    final net = _CardNet(answer: reply.future);
    tapCard('lnurlw://card.test/card');
    final c = charge(net);
    await c.card.arm();
    await settle();

    expect(c.events, ['idle', 'collecting', 'paid']);
    reply.complete();
    c.card.stop();
  });

  test('a failed verify poll does not drop the charge', () async {
    final net = _CardNet(failPolls: 1);
    tapCard('lnurlw://card.test/card');
    final c = charge(net);
    await c.card.arm();
    await settle();

    expect(c.events, ['idle', 'collecting', 'paid']);
    c.card.stop();
  });
}
