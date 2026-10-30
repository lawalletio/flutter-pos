import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/data/lnurl/lnurl_service.dart';
import 'package:lawallet_pos/features/cards/cards_api.dart';

/// Answers each request with [routes]`[METHOD path]` → (status, body), and
/// keeps what each one asked for. A String body goes out as it is.
class FakeNet implements HttpClientAdapter {
  FakeNet(this.routes);
  final Map<String, (int, Object)> routes;
  final requests = <RequestOptions>[];

  /// Routes that time out instead of answering.
  final timeouts = <String>{};

  @override
  Future<ResponseBody> fetch(
      RequestOptions o, Stream<Uint8List>? _, Future<void>? __) async {
    requests.add(o);
    final key = '${o.method} ${o.uri.path}';
    if (timeouts.contains(key)) {
      throw DioException(
          requestOptions: o, type: DioExceptionType.receiveTimeout);
    }
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

/// Resolves the addresses of [callbacks] to that callback, and fails the
/// rest. Records each address it is asked for.
class FakeLnurl extends LnurlService {
  final callbacks = <String, String>{};
  final resolved = <String>[];

  @override
  Future<LnurlPayParams> resolve(String address) async {
    resolved.add(address);
    final callback = callbacks[address];
    if (callback == null) {
      throw LnurlException('La dirección no es una Lightning Address válida');
    }
    return LnurlPayParams(
        callback: callback, minSendable: 1000, maxSendable: 100000000);
  }
}

/// What a LaWallet card sends: where its info is, then the SUN that spends it.
const _tap = 'lnurlw://beta.lawallet.io/api/cards/c1/scan?p=A1B2&c=C3D4';
const _infoRoute = 'GET /api/cards/c1/scan';
const _settingsRoute = 'GET /api/settings';

/// The info of card c1, owned by [user] (null when nobody paired it).
(int, Object) infoReply({Object? user = const {'username': 'ana'}}) => (
      200,
      {
        'id': 'c1',
        'title': 'Card',
        'paired': user != null,
        'used': true,
        'blocked': false,
        'disabled': false,
        'user': user,
      }
    );

/// The settings of an instance whose own domain is [domain].
(int, Object) settingsReply(String domain) => (
      200,
      {
        'domain': domain,
        'domain_verified': 'true',
        'endpoint': 'https://beta.lawallet.io',
      }
    );

void main() {
  late FakeNet net;
  late FakeLnurl fake;

  setUp(() {
    net = FakeNet({
      _infoRoute: infoReply(),
      _settingsRoute: settingsReply('LaWallet.io '),
    });
    fake = FakeLnurl()
      ..callbacks['ana@lawallet.io'] =
          'https://beta.lawallet.io/api/lud16/ana/callback';
  });

  Future<String> lookup([String tapUrl = _tap]) => cardOwnerAddress(tapUrl,
      dio: Dio()..httpClientAdapter = net, service: fake);

  /// The URL of each request, as it went out.
  List<String> urls() => [for (final o in net.requests) '${o.uri}'];

  test("gives the owner's address at the domain that pays here", () async {
    expect(await lookup(), 'ana@lawallet.io');
    expect(fake.resolved, ['ana@lawallet.io']);
  });

  test('asks for the info without the SUN, and never for the tap', () async {
    await lookup();

    expect(urls(), [
      'https://beta.lawallet.io/api/cards/c1/scan',
      'https://beta.lawallet.io/api/settings',
    ]);
    expect(net.requests.first.headers['x-request-action'], 'info');
    for (final o in net.requests) {
      expect(o.uri.query, isEmpty);
      expect('${o.uri}${o.headers}', isNot(contains('A1B2')));
      expect('${o.uri}${o.headers}', isNot(contains('C3D4')));
    }
  });

  group("gives the address at the card's host", () {
    Future<void> expectHost() async {
      expect(await lookup(), 'ana@beta.lawallet.io');
    }

    test('when the settings fail', () async {
      net.routes[_settingsRoute] = (500, {'error': 'boom'});
      await expectHost();
      expect(fake.resolved, isEmpty);
    });

    test('when the settings get no answer', () async {
      net.timeouts.add(_settingsRoute);
      await expectHost();
    });

    test('when the settings name no domain', () async {
      net.routes[_settingsRoute] = settingsReply(' ');
      await expectHost();
      expect(fake.resolved, isEmpty, reason: 'nothing to resolve');
    });

    test('when the domain does not resolve', () async {
      fake.callbacks.clear();
      await expectHost();
      expect(fake.resolved, ['ana@lawallet.io']);
    });

    test('when the domain pays through another host', () async {
      fake.callbacks['ana@lawallet.io'] = 'https://other.example/lud16/ana';
      await expectHost();
    });
  });

  test('a card its instance does not know is not found', () async {
    net.routes[_infoRoute] = (404, {'error': 'Card not found'});
    await expectLater(lookup(), throwsA(CardAddressError.notFound));
    expect(urls(), hasLength(1));
  });

  test('a card nobody paired, or whose owner has no username, has no address',
      () async {
    for (final user in [
      null,
      {'pubkey': 'ab12', 'username': null},
      {'pubkey': 'ab12', 'username': ''},
    ]) {
      net.requests.clear();
      net.routes[_infoRoute] = infoReply(user: user);
      await expectLater(lookup(), throwsA(CardAddressError.noAddress),
          reason: '$user');
      expect(urls(), hasLength(1), reason: 'the settings are not needed');
    }
  });

  test('a reply that is not the info leaves the card unread', () async {
    for (final reply in <(int, Object)>[
      (400, {'error': 'Bad request'}), // an instance older than the info
      (500, {'error': 'boom'}),
      (200, '{"user":'), // broken JSON
      (200, {'status': 'ERROR', 'reason': 'Replayed'}), // not the info
      (200, ['c1']),
    ]) {
      net.routes[_infoRoute] = reply;
      await expectLater(lookup(), throwsA(CardAddressError.unreadable),
          reason: '$reply');
    }
    net.timeouts.add(_infoRoute);
    await expectLater(lookup(), throwsA(CardAddressError.unreadable));
  });

  test('any other tag is not a LaWallet card, and nothing is asked', () async {
    for (final tag in [
      'lnurlw://bolt.example.com/withdraw?p=A1B2&c=C3D4', // another Boltcard
      '', // a blank one
      'hello /api/cards/c1/scan', // no host
    ]) {
      await expectLater(lookup(tag), throwsA(CardAddressError.notLaWallet),
          reason: tag);
    }
    expect(net.requests, isEmpty);
    expect(fake.resolved, isEmpty);
  });
}
