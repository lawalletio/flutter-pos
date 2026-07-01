import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/data/nostr/event.dart';
import 'package:lawallet_pos/data/nostr/signer.dart';

void main() {
  group('derivePublicKey (BIP-340 test vector)', () {
    test('secret key 3 → known x-only pubkey', () {
      const sk =
          '0000000000000000000000000000000000000000000000000000000000000003';
      const expected =
          'f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9';
      expect(derivePublicKey(sk).toLowerCase(), expected);
    });
  });

  group('signEvent / verifyEvent round-trip', () {
    const sk =
        '0000000000000000000000000000000000000000000000000000000000000003';

    test('signs a kind-1 order event and verifies', () {
      final unsigned = NostrEvent(
        pubkey: '',
        createdAt: 1700000000,
        kind: 1,
        tags: [
          ['t', 'order'],
          ['nonce', 'abc-123'],
        ],
        content: '',
      );

      final signed = signEvent(unsigned, sk);

      expect(signed.pubkey, derivePublicKey(sk));
      expect(signed.id, isNotNull);
      expect(signed.id!.length, 64);
      expect(signed.sig, isNotNull);
      expect(signed.sig!.length, 128);
      expect(verifyEvent(signed), isTrue);
    });

    test('tampered content fails verification', () {
      final unsigned = NostrEvent(
        pubkey: '',
        createdAt: 1700000000,
        kind: 9734,
        tags: const [],
        content: '',
      );
      final signed = signEvent(unsigned, sk);

      // Same signature/id but different content → id mismatch → invalid.
      final tampered = NostrEvent(
        id: signed.id,
        pubkey: signed.pubkey,
        createdAt: signed.createdAt,
        kind: signed.kind,
        tags: signed.tags,
        content: 'tampered',
        sig: signed.sig,
      );
      expect(verifyEvent(tampered), isFalse);
    });
  });
}
