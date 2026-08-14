import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/data/nostr/catalog.dart';
import 'package:lawallet_pos/data/nostr/event.dart';

/// Grouping products into menu sections.
///
/// The rule under test throughout: `t` (the slug) is authoritative for
/// MEMBERSHIP, and a category's `a` list only ORDERS products within its group.
/// Drift between the two costs ordering, never a product disappearing.

final merchant = 'a' * 64;

NostrEvent product(
  String d, {
  required String title,
  List<String> slugs = const [],
  String price = '10',
}) =>
    NostrEvent(
      pubkey: merchant,
      createdAt: 1000,
      kind: kindProduct,
      content: '',
      tags: [
        ['d', d],
        ['title', title],
        ['price', price, 'ARS'],
        for (final s in slugs) ['t', s],
      ],
    );

NostrEvent category(
  String d, {
  required String title,
  required String slug,
  int order = 0,
  int createdAt = 1000,
  List<String> productDs = const [],
}) =>
    NostrEvent(
      pubkey: merchant,
      createdAt: createdAt,
      kind: kindCategory,
      content: '',
      tags: [
        ['d', d],
        ['title', title],
        ['order', '$order'],
        ['t', slug],
        for (final p in productDs) ['a', '$kindProduct:$merchant:$p'],
      ],
    );

void main() {
  test('two live categories sharing a slug render once, with no duplicates', () {
    // The named production bug in the reference: a merchant who deleted
    // "Comida" and recreated it saw the section twice with every item in both.
    final events = [
      category('old', title: 'Comida vieja', slug: 'comida', createdAt: 1000),
      category('new', title: 'Comida', slug: 'comida', createdAt: 2000),
      product('p1', title: 'Empanada', slugs: ['comida']),
    ];

    final c = buildCatalog(events, merchant);

    expect(c.categories.length, 1);
    expect(c.categories.single.name, 'Comida'); // newest wins
    expect(c.products.length, 1); // and NOT twice
  });

  test('the first slug with a real category wins; others fall through', () {
    final events = [
      category('c', title: 'Bebidas', slug: 'bebidas'),
      // `promo` has no category, so `bebidas` is the primary.
      product('p', title: 'Fernet', slugs: ['promo', 'bebidas']),
    ];

    final c = buildCatalog(events, merchant);
    final bebidas = c.categories.single;
    expect(c.products.single.categoryId, bebidas.id);
  });

  test('a product with no matching category lands in the id-0 bucket', () {
    final c = buildCatalog([
      product('p', title: 'Suelto', slugs: ['nope']),
    ], merchant);

    expect(c.products.single.categoryId, 0);
    // Deliberately absent from `categories` so the menu screen's existing
    // `catName[id] ?? tr('Otros')` names and translates it.
    expect(c.categories, isEmpty);
  });

  test('`a` order drives order within a group; strays sort to the tail', () {
    final events = [
      category('c',
          title: 'Tragos', slug: 'tragos', productDs: ['p2', 'p1']),
      product('p1', title: 'Aaa', slugs: ['tragos']),
      product('p2', title: 'Zzz', slugs: ['tragos']),
      // Not listed in `a` at all — keeps its membership, sorts last by title.
      product('p3', title: 'Bbb', slugs: ['tragos']),
    ];

    final c = buildCatalog(events, merchant);
    expect(c.products.map((p) => p.name), ['Zzz', 'Aaa', 'Bbb']);
  });

  test('sections follow the `order` tag, uncategorised always last', () {
    final events = [
      category('c2', title: 'Segunda', slug: 'segunda', order: 2),
      category('c1', title: 'Primera', slug: 'primera', order: 1),
      product('p2', title: 'B', slugs: ['segunda']),
      product('p1', title: 'A', slugs: ['primera']),
      product('p0', title: 'Z', slugs: const []),
    ];

    final c = buildCatalog(events, merchant);
    expect(c.categories.map((e) => e.name), ['Primera', 'Segunda']);
    // Flattened in section order, with the uncategorised bucket at the end.
    expect(c.products.map((p) => p.name), ['A', 'B', 'Z']);
    expect(c.products.last.categoryId, 0);
  });

  test('an empty category renders no section', () {
    final c = buildCatalog([
      category('c', title: 'Vacía', slug: 'vacia'),
    ], merchant);
    expect(c.categories, isEmpty);
    expect(c.products, isEmpty);
  });

  test('ids are unique across the projection', () {
    final events = [
      category('c1', title: 'Uno', slug: 'uno', order: 1),
      category('c2', title: 'Dos', slug: 'dos', order: 2),
      for (var i = 0; i < 5; i++)
        product('p$i', title: 'P$i', slugs: [i.isEven ? 'uno' : 'dos']),
    ];

    final c = buildCatalog(events, merchant);
    final ids = c.products.map((p) => p.id).toSet();
    // The cart is keyed by product id — a collision would make one tile's
    // "+" bump another tile's quantity.
    expect(ids.length, c.products.length);
    expect(ids.contains(0), isFalse); // 0 is the uncategorised category id
  });
}

