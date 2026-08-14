import 'dart:convert';

import 'package:dio/dio.dart';

import '../lnurl/lnurl_helpers.dart';
import 'event.dart';
import 'relay_pool.dart';

final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');

/// Resolves a Lightning Address to its Nostr identity:
/// NIP-05 (`.well-known/nostr.json`) → pubkey → kind-0 metadata from relays.
class NostrProfileService {
  NostrProfileService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              // A merchant domain that hangs would otherwise stall the menu
              // forever: this was a bare Dio() with no timeouts.
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
            ));

  final Dio _dio;
  final Map<String, String?> _avatarCache = {};
  final Map<String, ({String pubkey, List<String> relays})?> _nip05Cache = {};

  // Profile-heavy relays queried in parallel for the kind-0 event.
  static const _relays = [
    'wss://purplepag.es',
    'wss://nos.lol',
    'wss://relay.primal.net',
    'wss://relay.damus.io',
  ];

  /// Avatar URL for [address], or null if NIP-05 / profile / picture is missing.
  Future<String?> avatarFor(String address) async {
    final key = address.trim().toLowerCase();
    if (_avatarCache.containsKey(key)) return _avatarCache[key];

    String? avatar;
    try {
      final id = await resolveNip05(key);
      if (id != null) avatar = await _fetchPicture(id.pubkey);
    } catch (_) {
      avatar = null;
    }
    _avatarCache[key] = avatar;
    return avatar;
  }

  /// NIP-05: `user@domain` → hex pubkey, plus any relay hints the document
  /// carries (a free outbox hint, absent on most static deployments).
  ///
  /// NIP-05 is IDENTIFICATION, NOT VERIFICATION: the pubkey is the identity and
  /// the address is only a label for it.
  ///
  /// The `?name=` query is a hint, not a contract — lacrypta.ar and plenty of
  /// other static hosts return the whole `names` map regardless — so the
  /// local-part lookup has to happen here, not on the server.
  Future<({String pubkey, List<String> relays})?> resolveNip05(
      String address) async {
    final key = address.trim().toLowerCase();
    if (_nip05Cache.containsKey(key)) return _nip05Cache[key];

    final result = await _resolveNip05(key);
    _nip05Cache[key] = result;
    return result;
  }

  Future<({String pubkey, List<String> relays})?> _resolveNip05(
      String address) async {
    final parts = extractEmailParts(address);
    final user = parts.username;
    if (user == null || parts.domain == null) return null;

    try {
      final res = await _dio.getUri(Uri.parse(nip05ToUrl(address)));
      final data = _asMap(res.data);
      final names = data?['names'];
      if (names is! Map) return null;

      final pubkey = (names[user] as String?)?.trim().toLowerCase();
      // Anything that is not 32 bytes of hex cannot be a pubkey, and this value
      // decides which catalog we sell from.
      if (pubkey == null || !_hex64.hasMatch(pubkey)) return null;

      final hints = <String>[];
      final relayMap = data?['relays'];
      if (relayMap is Map) {
        for (final r in (relayMap[pubkey] as List?) ?? const []) {
          final url = r.toString();
          if (url.startsWith('wss://')) hints.add(url);
        }
      }
      return (pubkey: pubkey, relays: hints);
    } catch (_) {
      return null;
    }
  }

  /// Newest kind-0 across the profile relays.
  Future<String?> _fetchPicture(String pubkey) async {
    final result = await fetchEvents(
      [
        {
          'kinds': [0],
          'authors': [pubkey],
          'limit': 1,
        }
      ],
      relays: _relays,
    );

    // Newest wins rather than first-to-answer: a lagging relay can still be
    // serving a profile the merchant has since replaced.
    NostrEvent? newest;
    for (final e in result.events) {
      if (e.kind != 0 || e.pubkey != pubkey) continue;
      if (newest == null || e.createdAt > newest.createdAt) newest = e;
    }
    if (newest == null) return null;

    try {
      final content = jsonDecode(newest.content);
      if (content is! Map) return null;
      final picture = content['picture'] as String?;
      return (picture != null && picture.isNotEmpty) ? picture : null;
    } catch (_) {
      return null;
    }
  }
}

/// dio on web often returns the JSON body as a String; normalize to a Map.
Map<String, dynamic>? _asMap(dynamic data) {
  if (data is Map) return data.cast<String, dynamic>();
  if (data is String && data.isNotEmpty) {
    try {
      final decoded = jsonDecode(data);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {}
  }
  return null;
}

final NostrProfileService nostrProfile = NostrProfileService();
