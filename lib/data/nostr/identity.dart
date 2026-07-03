import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'signer.dart';

/// The app's own Nostr identity, used to sign NIP-57 zap requests (kind 9734).
/// The private key is generated once and persisted (shared_preferences) so the
/// POS keeps a stable pubkey across sessions.
class NostrIdentity {
  static const _key = 'nostrPrivateKey';
  String? _priv;

  Future<String> privateKey() async {
    if (_priv != null) return _priv!;
    final prefs = await SharedPreferences.getInstance();
    var hexKey = prefs.getString(_key);
    if (hexKey == null || hexKey.length != 64) {
      hexKey = _generateHex();
      await prefs.setString(_key, hexKey);
    }
    return _priv = hexKey;
  }

  Future<String> publicKey() async => derivePublicKey(await privateKey());

  String _generateHex() {
    final rng = Random.secure();
    final bytes =
        Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256)));
    return hex.encode(bytes);
  }
}

final NostrIdentity nostrIdentity = NostrIdentity();
