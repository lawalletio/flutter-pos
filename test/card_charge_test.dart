import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/data/lnurl/lnurl_service.dart';
import 'package:lawallet_pos/features/payment/card_charge.dart';

/// Answers the card's withdrawRequest, its callback and the LUD-21 verify URL.
class _CardNet implements HttpClientAdapter {
  _CardNet({this.callback = '{"status":"OK"}'});
  final String callback;
  final paidInvoices = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final uri = options.uri;
    final body = switch (uri.path) {
      '/card' => '{"tag":"withdrawRequest","callback":"https://card.test/cb",'
          '"k1":"k"}',
      '/cb' => () {
          paidInvoices.add(uri.queryParameters['pr']!);
          return callback;
        }(),
      _ => '{"status":"OK","settled":true}',
    };
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

  setUp(() {
    messenger.setMockMethodCallHandler(const MethodChannel('pos/nfc'),
        (call) async => call.method == 'stopSession' ? null : true);
  });

  /// Delivers [cardUrl] on the tag stream once the reader is listening.
  void tapCard(String cardUrl) {
    messenger.setMockStreamHandler(
      const EventChannel('pos/nfc/tags'),
      MockStreamHandler.inline(
          onListen: (_, sink) => sink.success(cardUrl)),
    );
  }

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
    await pumpEventQueue();

    expect(c.card.available, isTrue);
    expect(net.paidInvoices, ['lnbc1invoice']);
    expect(c.events, ['idle', 'collecting', 'paid']);
    expect(c.card.collecting, isFalse);
    c.card.stop();
  });

  test('a rejected card reports the reason and goes back to waiting', () async {
    final net =
        _CardNet(callback: '{"status":"ERROR","reason":"Sin saldo"}');
    tapCard('lnurlw://card.test/card');
    final c = charge(net);
    await c.card.arm();
    await pumpEventQueue();

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
    c.card.stop();
  });
}
