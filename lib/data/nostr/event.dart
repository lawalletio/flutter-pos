import 'dart:convert';

import 'package:bech32/bech32.dart';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';

/// Nostr event primitives (NIP-01). Signing (BIP-340 schnorr) is wired in M2 via
/// the `bip340` package once its API is confirmed; the id/serialization here is
/// self-contained and golden-vector tested.

class NostrEvent {
  final String pubkey;
  final int createdAt;
  final int kind;
  final List<List<String>> tags;
  final String content;
  final String? id;
  final String? sig;

  const NostrEvent({
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required this.tags,
    required this.content,
    this.id,
    this.sig,
  });

  /// Canonical serialization used to derive the event id:
  /// `[0, pubkey, created_at, kind, tags, content]` (compact JSON, UTF-8).
  static String serialize({
    required String pubkey,
    required int createdAt,
    required int kind,
    required List<List<String>> tags,
    required String content,
  }) {
    return jsonEncode([0, pubkey, createdAt, kind, tags, content]);
  }

  /// Event id = sha256(serialization), hex.
  static String computeId({
    required String pubkey,
    required int createdAt,
    required int kind,
    required List<List<String>> tags,
    required String content,
  }) {
    final serialized = serialize(
      pubkey: pubkey,
      createdAt: createdAt,
      kind: kind,
      tags: tags,
      content: content,
    );
    return sha256.convert(utf8.encode(serialized)).toString();
  }

  String get computedId => computeId(
        pubkey: pubkey,
        createdAt: createdAt,
        kind: kind,
        tags: tags,
        content: content,
      );

  Map<String, dynamic> toJson() => {
        'id': id ?? computedId,
        'pubkey': pubkey,
        'created_at': createdAt,
        'kind': kind,
        'tags': tags,
        'content': content,
        if (sig != null) 'sig': sig,
      };

  factory NostrEvent.fromJson(Map<String, dynamic> j) => NostrEvent(
        id: j['id'] as String?,
        pubkey: j['pubkey'] as String,
        createdAt: j['created_at'] as int,
        kind: j['kind'] as int,
        tags: (j['tags'] as List)
            .map((t) => (t as List).map((e) => e.toString()).toList())
            .toList(),
        content: j['content'] as String? ?? '',
        sig: j['sig'] as String?,
      );
}

/// Decode a NIP-19 `npub` to a hex pubkey, or null if it is not one.
///
/// Bech32 with no length limit and no witness version — the `bech32` package's
/// segwit codec would reject both.
String? npubToHex(String npub) {
  if (!npub.startsWith('npub1')) return null;
  final Bech32 decoded;
  try {
    decoded = bech32.decode(npub, 200);
  } catch (_) {
    return null;
  }
  if (decoded.hrp != 'npub') return null;

  // 5-bit words back to bytes. Leftover bits must be zero padding, or the
  // string was not an encoding of 32 whole bytes.
  var acc = 0, bits = 0;
  final out = <int>[];
  for (final v in decoded.data) {
    acc = (acc << 5) | v;
    bits += 5;
    while (bits >= 8) {
      bits -= 8;
      out.add((acc >> bits) & 0xff);
    }
  }
  if (out.length != 32 || (acc & ((1 << bits) - 1)) != 0) return null;
  return hex.encode(out);
}
