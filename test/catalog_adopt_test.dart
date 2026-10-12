import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/data/nostr/relay_pool.dart';

/// When a catalog read that is not `complete` may still replace the menu.
void main() {
  const crypta = 'wss://relay.lacrypta.ar';
  const damus = 'wss://relay.damus.io';
  const wellorder = 'wss://nostr-pub.wellorder.net';
  final now = DateTime(2026, 10, 12, 12);

  test('a relay that never connected and never held the catalog is ignored', () {
    // relay.damus.io failing every handshake used to freeze the menu forever.
    expect(
      adoptableRead(
        connected: {crypta, wellorder},
        eosed: {crypta, wellorder},
        holders: {crypta: now.subtract(const Duration(hours: 7))},
        now: now,
      ),
      isTrue,
    );
  });

  test('a relay that connected but stopped before EOSE blocks the read', () {
    // Timed out or dropped mid-stream: what it was still sending is missing.
    expect(
      adoptableRead(
        connected: {crypta, wellorder},
        eosed: {wellorder},
        holders: const {},
        now: now,
      ),
      isFalse,
    );
  });

  test('a recent holder that did not answer blocks the read', () {
    // The intermittent relay that alone held the categories and deletions:
    // adopting without it resurrects deleted products.
    expect(
      adoptableRead(
        connected: {crypta},
        eosed: {crypta},
        holders: {crypta: now, damus: now.subtract(const Duration(hours: 1))},
        now: now,
      ),
      isFalse,
    );
  });

  test('a holder dead for longer than the TTL stops blocking', () {
    expect(
      adoptableRead(
        connected: {crypta},
        eosed: {crypta},
        holders: {crypta: now, damus: now.subtract(const Duration(days: 4))},
        now: now,
      ),
      isTrue,
    );
  });
}
