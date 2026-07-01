import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/data/nostr/event.dart';

void main() {
  group('NostrEvent.serialize', () {
    test('produces the canonical NIP-01 array (compact, ordered)', () {
      final s = NostrEvent.serialize(
        pubkey: 'abc',
        createdAt: 1,
        kind: 1,
        tags: [
          ['t', 'order']
        ],
        content: 'hi',
      );
      expect(s, '[0,"abc",1,1,[["t","order"]],"hi"]');
    });
  });

  group('sha256 wiring', () {
    test('matches the standard sha256("abc") vector', () {
      final digest = sha256.convert(utf8.encode('abc')).toString();
      expect(digest,
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    });
  });

  group('NostrEvent.computeId', () {
    test('id = sha256 of the canonical serialization', () {
      const pubkey = 'deadbeef';
      const createdAt = 1700000000;
      const kind = 9734;
      final tags = [
        ['amount', '1000'],
        ['p', 'recipient']
      ];
      const content = '';

      final expected = sha256
          .convert(utf8.encode(NostrEvent.serialize(
            pubkey: pubkey,
            createdAt: createdAt,
            kind: kind,
            tags: tags,
            content: content,
          )))
          .toString();

      final id = NostrEvent.computeId(
        pubkey: pubkey,
        createdAt: createdAt,
        kind: kind,
        tags: tags,
        content: content,
      );

      expect(id, expected);
      expect(id.length, 64);
    });

    test('computedId getter is stable for equal events', () {
      final e1 = NostrEvent(
          pubkey: 'p', createdAt: 5, kind: 1, tags: const [], content: 'x');
      final e2 = NostrEvent(
          pubkey: 'p', createdAt: 5, kind: 1, tags: const [], content: 'x');
      expect(e1.computedId, e2.computedId);
    });
  });
}
