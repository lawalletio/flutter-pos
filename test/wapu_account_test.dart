import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/features/wapu/wapu_account.dart';
import 'package:lawallet_pos/features/wapu/wapu_api.dart';

const _stage = 'https://be-stage.wapu.app';

/// A store holding one merchant's key.
const _saved = '{"a@x.ar":{"apiKey":"k","baseUrl":"$_stage"}}';

/// A storage whose reads fail the way a lost Keystore key does. With
/// [failDelete] the cleanup fails too.
class _BrokenStorage extends FlutterSecureStorage {
  const _BrokenStorage({this.failDelete = false});

  final bool failDelete;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      throw PlatformException(code: 'x');

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) =>
      failDelete ? throw PlatformException(code: 'y') : super.delete(key: key);
}

/// What the secure store holds, read around [WapuAccounts].
Future<String?> _raw() =>
    const FlutterSecureStorage().read(key: 'wapu.accounts');

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('saves and loads per merchant, ignoring case and spaces', () async {
    final accounts = WapuAccounts();
    await accounts.save(
      'Shop@LaCrypta.ar ',
      const WapuCredentials(apiKey: 'k1', baseUrl: _stage),
    );

    final got = await accounts.load('shop@lacrypta.ar');
    expect(got?.apiKey, 'k1');
    expect(got?.baseUrl, _stage);
  });

  test('a key saved without a URL uses production', () async {
    final accounts = WapuAccounts();
    await accounts.save('a@x.ar', const WapuCredentials(apiKey: 'k'));

    expect((await accounts.load('a@x.ar'))?.baseUrl, kWapuDefaultBaseUrl);
  });

  test('keeps one entry: a map keyed by the merchant address', () async {
    await wapuAccounts.save(
      ' Shop@LaCrypta.ar',
      const WapuCredentials(apiKey: 'k', baseUrl: _stage),
    );

    expect(jsonDecode((await _raw())!), {
      'shop@lacrypta.ar': {'apiKey': 'k', 'baseUrl': _stage},
    });
  });

  test('merchants are isolated and forget removes one', () async {
    final accounts = WapuAccounts();
    await accounts.save('a@x.ar', const WapuCredentials(apiKey: 'ka'));
    await accounts.save('b@x.ar', const WapuCredentials(apiKey: 'kb'));
    // Both are there first, or "A is gone" below would prove nothing.
    expect((await accounts.load('a@x.ar'))?.apiKey, 'ka');
    expect((await accounts.load('b@x.ar'))?.apiKey, 'kb');

    await accounts.forget(' A@x.ar');

    expect(await accounts.load('a@x.ar'), isNull);
    expect((await accounts.load('b@x.ar'))?.apiKey, 'kb');
  });

  test('saving a merchant again keeps the last key and the others', () async {
    final accounts = WapuAccounts();
    await accounts.save('a@x.ar', const WapuCredentials(apiKey: 'a1'));
    await accounts.save(
      'b@x.ar',
      const WapuCredentials(apiKey: 'kb', baseUrl: _stage),
    );

    await accounts.save(
      'A@x.ar ',
      const WapuCredentials(apiKey: 'a2', baseUrl: 'http://localhost:5000'),
    );

    final a = await accounts.load('a@x.ar');
    expect(a?.apiKey, 'a2');
    expect(a?.baseUrl, 'http://localhost:5000');
    final b = await accounts.load('b@x.ar');
    expect(b?.apiKey, 'kb');
    expect(b?.baseUrl, _stage);
  });

  test('forgetting a merchant that was never saved changes nothing', () async {
    final accounts = WapuAccounts();
    await accounts.save('a@x.ar', const WapuCredentials(apiKey: 'ka'));
    final before = await _raw();

    await accounts.forget('nobody@x.ar');
    await accounts.forget('');

    expect(await _raw(), before);
  });

  test('unknown or empty merchant loads null', () async {
    final accounts = WapuAccounts();
    await accounts.save('a@x.ar', const WapuCredentials(apiKey: 'ka'));

    expect(await accounts.load('nobody@x.ar'), isNull);
    expect(await accounts.load(''), isNull);
    expect(await accounts.load('   '), isNull);
  });

  test('an empty merchant saves nothing', () async {
    final accounts = WapuAccounts();
    await accounts.save('', const WapuCredentials(apiKey: 'k'));
    await accounts.save('  ', const WapuCredentials(apiKey: 'k'));

    expect(await _raw(), isNull);
  });

  test('malformed storage loads null', () async {
    for (final blob in [
      'not json',
      'null',
      '[]',
      '{"a@x.ar": "oops"}',
      '{"a@x.ar": null}',
      '{"a@x.ar": {"apiKey": 1, "baseUrl": "u"}}',
      '{"a@x.ar": {"apiKey": "k"}}',
    ]) {
      FlutterSecureStorage.setMockInitialValues({'wapu.accounts': blob});

      expect(await WapuAccounts().load('a@x.ar'), isNull, reason: blob);
    }
  });

  test('a failing read counts as no key', () async {
    FlutterSecureStorage.setMockInitialValues({'wapu.accounts': _saved});
    final accounts = WapuAccounts(storage: const _BrokenStorage());

    expect(await accounts.load('a@x.ar'), isNull);
  });

  test('storage that cannot be read is cleared', () async {
    FlutterSecureStorage.setMockInitialValues({'wapu.accounts': 'not json'});
    await WapuAccounts().load('a@x.ar');
    expect(await _raw(), isNull);

    FlutterSecureStorage.setMockInitialValues({'wapu.accounts': _saved});
    await WapuAccounts(storage: const _BrokenStorage()).load('a@x.ar');
    expect(await _raw(), isNull);
  });

  test('a key can be saved over malformed storage', () async {
    FlutterSecureStorage.setMockInitialValues({'wapu.accounts': 'not json'});
    final accounts = WapuAccounts();

    await accounts.save('a@x.ar', const WapuCredentials(apiKey: 'k'));

    expect((await accounts.load('a@x.ar'))?.apiKey, 'k');
  });

  test('a failing clear-up does not make load throw', () async {
    final accounts =
        WapuAccounts(storage: const _BrokenStorage(failDelete: true));

    expect(await accounts.load('a@x.ar'), isNull);
  });

  group('normalizeWapuBaseUrl', () {
    const cases = <String, String?>{
      // Kept, tidied.
      ' https://be-prod.wapu.app/ ': 'https://be-prod.wapu.app',
      'be-stage.wapu.app': _stage,
      'https://be-stage.wapu.app///': _stage,
      'https://be.wapu.app/api/': 'https://be.wapu.app/api',
      'localhost:5000': 'https://localhost:5000',
      // Plain http is for a backend on this machine or the emulator host.
      'http://localhost:5000': 'http://localhost:5000',
      'http://10.0.2.2:5000': 'http://10.0.2.2:5000',
      'http://127.0.0.1:8080/': 'http://127.0.0.1:8080',
      // Refused.
      'http://example.com': null,
      'http://localhost.evil.com': null,
      'http://localhost@evil.com': null,
      'ftp://x.com': null,
      'javascript:alert(1)': null,
      // No host.
      '': null,
      '   ': null,
      '/': null,
      'https://': null,
      // Not a bare base URL: user info would become a Basic header beside the
      // key, and WapuApi appends its paths to the base.
      'https://user:pw@be.wapu.app': null,
      'https://be.wapu.app?x=1': null,
      'https://be.wapu.app/#f': null,
      'https://be prod.wapu.app': null,
      // Only the three hosts above may use plain http, not the IPv6 loopback.
      'http://[::1]:5000': null,
    };

    cases.forEach((raw, want) {
      test("'$raw' -> $want", () => expect(normalizeWapuBaseUrl(raw), want));
    });
  });
}
