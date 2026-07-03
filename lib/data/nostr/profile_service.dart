import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../lnurl/lnurl_helpers.dart';

/// Resolves a Lightning Address to its Nostr profile avatar:
/// NIP-05 (`.well-known/nostr.json`) → pubkey → kind-0 metadata from relays.
class NostrProfileService {
  NostrProfileService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;
  final Map<String, String?> _avatarCache = {};

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
      final pubkey = await _resolvePubkey(key);
      if (pubkey != null) {
        avatar = await _fetchPicture(pubkey);
      }
    } catch (_) {
      avatar = null;
    }
    _avatarCache[key] = avatar;
    return avatar;
  }

  /// NIP-05: `user@domain` → hex pubkey via `.well-known/nostr.json?name=user`.
  Future<String?> _resolvePubkey(String address) async {
    final parts = extractEmailParts(address);
    if (parts.username == null || parts.domain == null) return null;
    final res = await _dio.getUri(Uri.parse(nip05ToUrl(address)));
    final data = _asMap(res.data);
    final names = data?['names'];
    if (names is Map) return names[parts.username] as String?;
    return null;
  }

  /// Race the relays for the first kind-0 event with a `picture`.
  Future<String?> _fetchPicture(String pubkey) async {
    final completer = Completer<String?>();
    final channels = <WebSocketChannel>[];
    final subs = <StreamSubscription>[];

    for (final url in _relays) {
      try {
        final ch = WebSocketChannel.connect(Uri.parse(url));
        channels.add(ch);
        ch.sink.add(jsonEncode([
          'REQ',
          'avatar',
          {
            'kinds': [0],
            'authors': [pubkey],
            'limit': 1,
          }
        ]));
        subs.add(ch.stream.listen((raw) {
          try {
            final arr = jsonDecode(raw as String) as List;
            if (arr.isNotEmpty && arr[0] == 'EVENT' && arr.length >= 3) {
              final content =
                  jsonDecode((arr[2] as Map)['content'] as String) as Map;
              final pic = content['picture'] as String?;
              if (pic != null && pic.isNotEmpty && !completer.isCompleted) {
                completer.complete(pic);
              }
            }
          } catch (_) {/* ignore malformed frames */}
        }, onError: (_) {}, cancelOnError: false));
      } catch (_) {/* relay unreachable */}
    }

    Timer(const Duration(seconds: 5), () {
      if (!completer.isCompleted) completer.complete(null);
    });

    final result = await completer.future;
    for (final s in subs) {
      unawaited(s.cancel());
    }
    for (final ch in channels) {
      try {
        unawaited(ch.sink.close());
      } catch (_) {}
    }
    return result;
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
