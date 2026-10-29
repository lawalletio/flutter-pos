/// Where each POS user keeps their WapuPay key and backend URL. One entry in
/// secure storage holds them all, keyed by the signed-in merchant address, so
/// a different user is asked for a key again and a returning one is not.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'wapu_api.dart' show kWapuDefaultBaseUrl;

const _storageKey = 'wapu.accounts';

/// Hosts that may be reached over plain `http`: a backend on this machine or
/// on the Android emulator's host loopback.
const _localHosts = {'localhost', '127.0.0.1', '10.0.2.2'};

class WapuCredentials {
  const WapuCredentials({
    required this.apiKey,
    this.baseUrl = kWapuDefaultBaseUrl,
  });

  final String apiKey;
  final String baseUrl;
}

/// Turns what a merchant typed into a backend URL: trimmed, `https://` assumed
/// when there is no scheme, no trailing slash. Null when it is not a bare base
/// URL (whitespace, user info, a query or a fragment: `WapuApi` appends its
/// paths to it, and user info would become a Basic `Authorization` header next
/// to the key), when there is no host, or when the key must not be sent there:
/// any scheme but `https`, with `http` allowed only for [_localHosts].
String? normalizeWapuBaseUrl(String raw) {
  var text = raw.trim();
  if (text.contains(RegExp(r'\s'))) return null;
  if (!text.contains('://')) text = 'https://$text';
  text = text.replaceFirst(RegExp(r'/+$'), '');
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) return null;
  final secure = uri.scheme == 'https';
  final local = uri.scheme == 'http' && _localHosts.contains(uri.host);
  return secure || local ? text : null;
}

/// The credentials saved on this device, one set per merchant address.
class WapuAccounts {
  WapuAccounts({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  /// Null when this merchant has no usable key: never saved, forgotten, or
  /// unreadable. An empty address never has one.
  Future<WapuCredentials?> load(String merchantAddress) async {
    final id = _id(merchantAddress);
    return id.isEmpty ? null : (await _readAll())[id];
  }

  Future<void> save(String merchantAddress, WapuCredentials c) async {
    final id = _id(merchantAddress);
    if (id.isEmpty) return;
    final all = await _readAll();
    all[id] = c;
    await _writeAll(all);
  }

  Future<void> forget(String merchantAddress) async {
    final all = await _readAll();
    if (all.remove(_id(merchantAddress)) != null) await _writeAll(all);
  }

  /// Every entry that can be read, and nothing else: it never changes the
  /// store. A read that fails (a locked or busy Keystore) counts as no keys for
  /// this call, and must not cost any merchant theirs. On Android the plugin
  /// itself resets its storage after the Keystore key is lost. Each entry is
  /// parsed on its own, so a malformed one is skipped and the others stay. Text
  /// that is not our map reads as empty, and a save then starts the map over.
  Future<Map<String, WapuCredentials>> _readAll() async {
    final String? raw;
    try {
      raw = await _storage.read(key: _storageKey);
    } catch (_) {
      return {};
    }
    if (raw == null) return {};
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return {};
    }
    if (decoded is! Map<String, dynamic>) return {};
    return {
      for (final e in decoded.entries)
        if (_credentials(e.value) case final c?) e.key: c,
    };
  }

  Future<void> _writeAll(Map<String, WapuCredentials> all) => _storage.write(
        key: _storageKey,
        value: jsonEncode({
          for (final e in all.entries)
            e.key: {'apiKey': e.value.apiKey, 'baseUrl': e.value.baseUrl},
        }),
      );
}

String _id(String merchantAddress) => merchantAddress.trim().toLowerCase();

/// The credentials in one stored entry, or null when it is not a usable one.
WapuCredentials? _credentials(Object? entry) {
  if (entry is! Map) return null;
  final apiKey = entry['apiKey'];
  final baseUrl = entry['baseUrl'];
  return apiKey is String && baseUrl is String
      ? WapuCredentials(apiKey: apiKey, baseUrl: baseUrl)
      : null;
}

/// The app's store. Tests swap it.
WapuAccounts wapuAccounts = WapuAccounts();
