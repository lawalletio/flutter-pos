import 'dart:math';
import 'dart:typed_data';

import 'package:bip340/bip340.dart' as bip340;
import 'package:convert/convert.dart';

import 'event.dart';

/// Nostr signing (NIP-01) over BIP-340 schnorr. This is the Dart equivalent of
/// nostr-tools `getPublicKey` / `finalizeEvent` / `verifyEvent`.

/// Derive the x-only public key (hex) from a 32-byte private key (hex).
String derivePublicKey(String privateKeyHex) =>
    bip340.getPublicKey(privateKeyHex);

/// Sign an unsigned event: fills `pubkey` (if absent), `id`, and `sig`.
/// Returns a new [NostrEvent] carrying the signature.
NostrEvent signEvent(NostrEvent unsigned, String privateKeyHex) {
  final pubkey = unsigned.pubkey.isNotEmpty
      ? unsigned.pubkey
      : derivePublicKey(privateKeyHex);

  final id = NostrEvent.computeId(
    pubkey: pubkey,
    createdAt: unsigned.createdAt,
    kind: unsigned.kind,
    tags: unsigned.tags,
    content: unsigned.content,
  );

  final sig = bip340.sign(privateKeyHex, id, _randomAuxHex());

  return NostrEvent(
    id: id,
    pubkey: pubkey,
    createdAt: unsigned.createdAt,
    kind: unsigned.kind,
    tags: unsigned.tags,
    content: unsigned.content,
    sig: sig,
  );
}

/// Verify an event's id + schnorr signature (mirrors nostr-tools `verifyEvent`).
bool verifyEvent(NostrEvent event) {
  if (event.id == null || event.sig == null) return false;
  if (event.id != event.computedId) return false;
  return bip340.verify(event.pubkey, event.id!, event.sig!);
}

String _randomAuxHex() {
  final rng = Random.secure();
  final bytes = Uint8List.fromList(
    List<int>.generate(32, (_) => rng.nextInt(256)),
  );
  return hex.encode(bytes);
}
