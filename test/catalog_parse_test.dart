import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/data/nostr/catalog.dart';
import 'package:lawallet_pos/data/nostr/event.dart';
import 'package:lawallet_pos/domain/config/currencies.dart';

/// Parsing NIP-99 events off untrusted relays. Every case here that returns
/// null or drops a product is a product that does NOT get rung up at a wrong
/// price, so the table is the money contract.

final merchant = 'a' * 64;
final stranger = 'b' * 64;

NostrEvent ev({
  required int kind,
  String? pubkey,
  int createdAt = 1000,
  List<List<String>> tags = const [],
  String content = '',
  String? id,
}) =>
    NostrEvent(
      pubkey: pubkey ?? merchant,
      createdAt: createdAt,
      kind: kind,
      tags: tags,
      content: content,
      id: id,
    );

NostrEvent product(String d, List<List<String>> extra) => ev(
      kind: kindProduct,
      tags: [
        ['d', d],
        ['title', d],
        ...extra,
      ],
    );

void main() {
  group('parsePriceTag', () {
    test('plain decimal and es-AR thousands both parse', () {
      expect(parsePriceTag(['price', '2100', 'ARS'])!.amount, 2100);
      expect(parsePriceTag(['price', '1234.56', 'ARS'])!.amount, 1234.56);
      // "1.234,56" must not read as 1.234
      expect(parsePriceTag(['price', '1.234,56', 'ARS'])!.amount, 1234.56);
    });

    test('BTC converts to sats; the float tail is rounded away', () {
      final p = parsePriceTag(['price', '0.0021', 'btc'])!;
      expect(p.currency, 'SAT');
      expect(p.amount, 210000); // NOT 0, which Currency.fromCode used to give
    });

    test('SAT and SATS normalise; a fractional sat is refused', () {
      expect(parsePriceTag(['price', '1000', 'SATS'])!.amount, 1000);
      expect(parsePriceTag(['price', '1000', 'sat'])!.currency, 'SAT');
      // Millisats or a unit mix-up — rounding would silently change the price.
      expect(parsePriceTag(['price', '1.5', 'SAT']), isNull);
    });

    test('unreadable amounts are refused, not defaulted', () {
      expect(parsePriceTag(['price', '', 'ARS']), isNull);
      expect(parsePriceTag(['price', 'consultar', 'ARS']), isNull);
      expect(parsePriceTag(['price', '-5', 'ARS']), isNull);
      expect(parsePriceTag(['price', '10']), isNull); // no currency
      expect(parsePriceTag(null), isNull);
      expect(parsePriceTag(['title', 'x', 'y']), isNull);
    });

    test('an unconvertible currency parses but is not a Currency', () {
      final p = parsePriceTag(['price', '25', 'EUR'])!;
      expect(p.currency, 'EUR');
      expect(CurrencyX.tryFromCode(p.currency), isNull);
    });

    test('a recurring price is carried so it can be refused', () {
      expect(parsePriceTag(['price', '10', 'USD', 'month'])!.frequency, 'month');
      expect(parsePriceTag(['price', '10', 'USD'])!.frequency, isNull);
    });
  });

  group('buildCatalog filtering', () {
    test('keeps only what a till can actually charge', () {
      final events = [
        product('ok', [
          ['price', '2100', 'ARS']
        ]),
        product('eur', [
          ['price', '25', 'EUR']
        ]),
        product('recurring', [
          ['price', '10', 'USD', 'month']
        ]),
        product('priceless', const []),
        product('free', [
          ['price', '0', 'ARS']
        ]),
      ];

      final c = buildCatalog(events, merchant);
      expect(c.products.map((p) => p.name), ['ok']);
      // Four dropped for price reasons — surfaced so the menu does not just
      // silently shrink.
      expect(c.unsellable, 4);
    });

    test('merchant intent (hidden/sold) is not counted as unsellable', () {
      final events = [
        product('hidden', [
          ['price', '10', 'ARS'],
          ['visibility', 'hidden']
        ]),
        product('sold', [
          ['price', '10', 'ARS'],
          ['status', 'sold']
        ]),
        product('preorder', [
          ['price', '10', 'ARS'],
          ['visibility', 'pre-order']
        ]),
      ];

      final c = buildCatalog(events, merchant);
      // pre-order is sellable; hidden and sold are not, but neither is a defect.
      expect(c.products.map((p) => p.name), ['preorder']);
      expect(c.unsellable, 0);
    });

    test('events from another pubkey are dropped even if the relay sent them',
        () {
      final events = [
        product('mine', [
          ['price', '10', 'ARS']
        ]),
        ev(kind: kindProduct, pubkey: stranger, tags: [
          ['d', 'theirs'],
          ['title', 'Injected'],
          ['price', '1', 'ARS'],
        ]),
      ];
      expect(buildCatalog(events, merchant).products.map((p) => p.name),
          ['mine']);
    });

    test('prices survive into the projection with their own currency', () {
      final c = buildCatalog([
        product('usd', [
          ['price', '25', 'USD']
        ]),
      ], merchant);
      expect(c.products.single.priceCurrency, Currency.usd);
      expect(c.products.single.priceValue, 25);
    });
  });

  group('isOurCollection', () {
    List<List<String>> baseTags = [
      ['d', 'cat1'],
      ['title', 'Tragos'],
      ['t', 'tragos'],
    ];

    test('accepts a real collection', () {
      expect(isOurCollection(ev(kind: kindCategory, tags: baseTags), merchant),
          isTrue);
    });

    test('rejects another pubkey', () {
      expect(
          isOurCollection(
              ev(kind: kindCategory, pubkey: stranger, tags: baseTags),
              merchant),
          isFalse);
    });

    test('rejects a Shopstr encrypted cart', () {
      // Carts have no title...
      expect(
          isOurCollection(
              ev(kind: kindCategory, tags: [
                ['d', 'cart']
              ]),
              merchant),
          isFalse);
      // ...address a counterparty...
      expect(
          isOurCollection(
              ev(kind: kindCategory, tags: [...baseTags, ['p', stranger]]),
              merchant),
          isFalse);
      // ...and carry a NIP-44 blob as content.
      expect(
          isOurCollection(
              ev(
                kind: kindCategory,
                tags: baseTags,
                content: 'A${'x' * 60}==',
              ),
              merchant),
          isFalse);
    });

    test('rejects an `a` tag that is not a product/category coordinate', () {
      expect(
          isOurCollection(
              ev(kind: kindCategory, tags: [
                ...baseTags,
                ['a', 'not-a-coordinate']
              ]),
              merchant),
          isFalse);
    });
  });

  group('latestByAddress', () {
    test('newest created_at wins', () {
      final old = product('x', [
        ['price', '1', 'ARS']
      ]);
      final fresh = ev(kind: kindProduct, createdAt: 2000, tags: [
        ['d', 'x'],
        ['title', 'new'],
      ]);
      final live = latestByAddress([old, fresh]);
      expect(live.single.createdAt, 2000);
    });

    test('an equal created_at breaks to the lowest id, not relay order', () {
      final a = ev(kind: kindProduct, id: 'ffff', tags: [
        ['d', 'x']
      ]);
      final b = ev(kind: kindProduct, id: '0000', tags: [
        ['d', 'x']
      ]);
      expect(latestByAddress([a, b]).single.id, '0000');
      expect(latestByAddress([b, a]).single.id, '0000');
    });
  });

  group('liveEventsFor (what gets replicated)', () {
    test('keeps the newest version, drops superseded ones', () {
      final old = ev(kind: kindProduct, createdAt: 100, id: 'a' * 64, tags: [
        ['d', 'p'],
        ['price', '10', 'ARS'],
      ]);
      final now = ev(kind: kindProduct, createdAt: 200, id: 'b' * 64, tags: [
        ['d', 'p'],
        ['price', '20', 'ARS'],
      ]);
      final live = liveEventsFor([old, now], merchant);
      // A product repriced ten times must not be republished ten times.
      expect(live.map((e) => e.id), ['b' * 64]);
    });

    test('carries deletions so they propagate to relays missing them', () {
      final del = ev(kind: kindDeletion, createdAt: 300, tags: [
        ['a', '$kindProduct:$merchant:gone']
      ]);
      final other = ev(kind: kindProduct, createdAt: 100, tags: [
        ['d', 'kept']
      ]);
      final live = liveEventsFor([del, other], merchant);
      expect(live.where((e) => e.kind == kindDeletion), hasLength(1));
    });

    test('drops deleted products and foreign authors', () {
      final gone = ev(kind: kindProduct, createdAt: 100, tags: [
        ['d', 'gone']
      ]);
      final del = ev(kind: kindDeletion, createdAt: 300, tags: [
        ['a', '$kindProduct:$merchant:gone']
      ]);
      final theirs = ev(kind: kindProduct, pubkey: stranger, tags: [
        ['d', 'x']
      ]);
      final live = liveEventsFor([gone, del, theirs], merchant);
      expect(live.where((e) => e.kind == kindProduct), isEmpty);
      expect(live.every((e) => e.pubkey == merchant), isTrue);
    });
  });

  group('deletions', () {
    String coord(String d) => '$kindProduct:$merchant:$d';

    test('a deletion covers its own created_at, and a later republish wins', () {
      final del = ev(kind: kindDeletion, createdAt: 100, tags: [
        ['a', coord('x')]
      ]);
      final index = buildDeletionIndex([del]);

      final same = ev(kind: kindProduct, createdAt: 100, tags: [
        ['d', 'x']
      ]);
      final later = ev(kind: kindProduct, createdAt: 101, tags: [
        ['d', 'x']
      ]);
      expect(isDeleted(same, index), isTrue); // >= not >
      expect(isDeleted(later, index), isFalse); // legitimately resurrected
    });

    test('nobody deletes anybody else\'s events', () {
      // A relay can inject any kind-5 it likes; NIP-09 makes the author check a
      // client MUST.
      final hostile = ev(kind: kindDeletion, pubkey: stranger, tags: [
        ['a', coord('x')]
      ]);
      expect(buildDeletionIndex([hostile]), isEmpty);
    });

    test('a deleted product does not reach the menu', () {
      final events = [
        product('gone', [
          ['price', '10', 'ARS']
        ]),
        ev(kind: kindDeletion, createdAt: 5000, tags: [
          ['a', coord('gone')]
        ]),
      ];
      expect(buildCatalog(events, merchant).products, isEmpty);
    });
  });
}
