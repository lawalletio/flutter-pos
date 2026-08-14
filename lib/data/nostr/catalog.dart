import 'package:flutter/foundation.dart';

import '../../domain/config/currencies.dart';
import '../../domain/order/product.dart';
import 'event.dart';

/// The merchant's catalog, read from nostr — the pure half: no I/O, no widgets,
/// no clock. [buildCatalog] takes raw relay events and returns the menu.
///
/// Wire format ported from lacrypta/merchant, the panel merchants publish with.
/// Its README names this repo as one of three keeping a hand-copied JSON of the
/// same catalog; this is the read side of that fix.
///
/// Everything here treats relay output as hostile. `authors:` in a REQ is a
/// request, not a guarantee, so authorship is re-checked locally and every rule
/// below fails closed.

/// NIP-99 classified listing — a published product.
const int kindProduct = 30402;

/// GammaMarkets product collection, used as a category.
/// WARNING: Shopstr uses this same kind for NIP-44 encrypted shopping carts.
/// See [isOurCollection].
const int kindCategory = 30405;

/// NIP-09 deletion request.
const int kindDeletion = 5;

// ---------------------------------------------------------------- tag helpers

String? _tagValue(NostrEvent e, String name) {
  for (final t in e.tags) {
    if (t.isNotEmpty && t[0] == name && t.length >= 2) return t[1];
  }
  return null;
}

List<String> _tagValues(NostrEvent e, String name) => [
      for (final t in e.tags)
        if (t.isNotEmpty && t[0] == name && t.length >= 2) t[1],
    ];

bool _hasTag(NostrEvent e, String name) =>
    e.tags.any((t) => t.isNotEmpty && t[0] == name);

// --------------------------------------------------------------------- slugs

final RegExp _nonSlug = RegExp(r'[^a-z0-9]+');
final RegExp _edgeDashes = RegExp(r'^-+|-+$');

/// Category slug — the `t` tag that binds a product to its category.
///
/// The reference additionally strips combining marks through NFD, which
/// `dart:core` cannot do. It does not matter here: the panel slugifies at
/// WRITE time, so `t` tags on the wire are already ASCII and re-slugifying is
/// idempotent. If some other client ever writes a raw accented `t`, `café`
/// folds to `caf-` here versus `cafe` there — but BOTH sides of the link run
/// through this same function, so product and category still agree and
/// membership survives. Not worth a Unicode normalization dependency.
String slugify(String input) {
  final s = input
      .toLowerCase()
      .replaceAll(_nonSlug, '-')
      .replaceAll(_edgeDashes, '');
  return s.length <= 64 ? s : s.substring(0, 64);
}

// --------------------------------------------------------------------- price

/// A price as published. [currency] is uppercase, with `BTC` and `SATS`
/// already folded to `SAT` (and the amount converted).
@immutable
class NostrPrice {
  final num amount;
  final String currency;

  /// NIP-99 recurring interval ("month", …). Present means a subscription
  /// price, which a till cannot ring up as a one-off sale.
  final String? frequency;

  const NostrPrice(this.amount, this.currency, [this.frequency]);
}

const int _satsPerBtc = 100000000;

/// Parse a NIP-99 `["price", amount, currency, frequency?]` tag.
///
/// Returns null for anything unreadable rather than guessing — every null here
/// removes a product from the menu, which is strictly better than ringing up a
/// price nobody published.
NostrPrice? parsePriceTag(List<String>? tag) {
  if (tag == null || tag.length < 3 || tag[0] != 'price') return null;

  final rawAmount = tag[1].trim();
  final rawCurrency = tag[2].trim();
  if (rawAmount.isEmpty || rawCurrency.isEmpty) return null;

  // Accept "1.234,56" (es-AR) alongside "1234.56". The spec's own examples use
  // both conventions and a misread here is a mischarge.
  final normalised = rawAmount.contains(',')
      ? rawAmount.replaceAll('.', '').replaceAll(',', '.')
      : rawAmount;
  final amount = double.tryParse(normalised);
  if (amount == null || !amount.isFinite || amount < 0) return null;

  final frequency =
      tag.length >= 4 && tag[3].trim().isNotEmpty ? tag[3].trim() : null;
  final code = rawCurrency.toUpperCase();

  if (code == 'BTC') {
    final sats = amount * _satsPerBtc;
    if (!sats.isFinite) return null;
    // 0.0021 * 1e8 lands on 210000.00000000003 in binary floating point;
    // rounding is the conversion, not a fudge.
    return NostrPrice(sats.round(), 'SAT', frequency);
  }
  if (code == 'SAT' || code == 'SATS') {
    // A fractional "sat" is millisats or a unit mix-up. Rounding would quietly
    // change the price, so refuse the product instead.
    if (amount != amount.roundToDouble()) return null;
    return NostrPrice(amount.round(), 'SAT', frequency);
  }
  return NostrPrice(amount, code, frequency);
}

// ------------------------------------------------------------------- models

@immutable
class NostrProduct {
  /// Addressable identifier (a uuid, per the reference — never derived from the
  /// title, so renaming does not orphan the listing).
  final String d;
  final String title;
  final String description;
  final NostrPrice? price;
  final String status; // active | sold
  final String visibility; // hidden | on-sale | pre-order

  /// Ordered. Tag order encodes priority, so index 0 is the primary category.
  final List<String> categorySlugs;
  final List<String> imageUrls;
  final int updatedAt;

  const NostrProduct({
    required this.d,
    required this.title,
    required this.description,
    required this.price,
    required this.status,
    required this.visibility,
    required this.categorySlugs,
    required this.imageUrls,
    required this.updatedAt,
  });
}

@immutable
class NostrCategory {
  final String d;
  final String name;

  /// Equals the `t` tag on BOTH sides of the link — this is what binds
  /// membership together, so it is locked after creation.
  final String slug;
  final String? emoji;
  final int order;

  /// From `a` tags: the curated order of products WITHIN this category.
  final List<String> productDs;
  final int updatedAt;

  const NostrCategory({
    required this.d,
    required this.name,
    required this.slug,
    required this.emoji,
    required this.order,
    required this.productDs,
    required this.updatedAt,
  });
}

// ------------------------------------------------------------------- parsing

/// Parse a kind-30402 into a product, or null if it is not one.
NostrProduct? parseProductEvent(NostrEvent e) {
  if (e.kind != kindProduct) return null;

  final d = _tagValue(e, 'd');
  if (d == null || d.isEmpty) return null;

  // The panel's own tombstones carry ["deleted", ""] — they are not products.
  if (_hasTag(e, 'deleted')) return null;

  // ["image", url, "WxH", order] — order is advisory, tag order is the tiebreak.
  final images = <({String url, int order})>[];
  for (final t in e.tags) {
    if (t.isEmpty || t[0] != 'image' || t.length < 2 || t[1].isEmpty) continue;
    final ord = t.length >= 4 ? int.tryParse(t[3]) ?? images.length : images.length;
    images.add((url: t[1], order: ord));
  }
  images.sort((a, b) => a.order.compareTo(b.order));

  final slugs = <String>[];
  for (final raw in _tagValues(e, 't')) {
    final s = slugify(raw);
    if (s.isNotEmpty && !slugs.contains(s)) slugs.add(s);
  }

  return NostrProduct(
    d: d,
    title: _tagValue(e, 'title') ?? '(sin título)',
    description: e.content,
    price: parsePriceTag(_firstTagRow(e, 'price')),
    // Spec defaults, applied explicitly: an absent tag means the common case,
    // not a broken listing.
    status: _tagValue(e, 'status') == 'sold' ? 'sold' : 'active',
    visibility: _tagValue(e, 'visibility') ?? 'on-sale',
    categorySlugs: slugs,
    imageUrls: [for (final i in images) i.url],
    updatedAt: e.createdAt,
  );
}

List<String>? _firstTagRow(NostrEvent e, String name) {
  for (final t in e.tags) {
    if (t.isNotEmpty && t[0] == name) return t;
  }
  return null;
}

/// NIP-44 v2 payloads base64 to a leading 'A'.
final RegExp _nip44B64 = RegExp(r'^A[A-Za-z0-9+/]{40,}={0,2}$');
final RegExp _productCoord = RegExp(r'^3040[23]:[0-9a-f]{64}:');

/// Is this kind-30405 one of ours, or a Shopstr encrypted shopping cart?
///
/// Shopstr uses kind 30405 for a NIP-44 ENCRYPTED CART while GammaMarkets uses
/// it for product collections. Reading a cart as a category renders base64 as a
/// section header, so this validates POSITIVELY rather than blocklisting.
bool isOurCollection(NostrEvent e, String merchantPubkey) {
  if (e.kind != kindCategory) return false;
  if (e.pubkey != merchantPubkey) return false;

  // Carts have no title.
  if (_tagValue(e, 'd') == null || _tagValue(e, 'title') == null) return false;
  // Carts address a counterparty.
  if (_hasTag(e, 'p')) return false;

  final content = e.content.trim();
  if (content.isNotEmpty) {
    // Ours is always empty; an encrypted blob is definitively not ours.
    if (_nip44B64.hasMatch(content) || content.length > 512) return false;
  }

  for (final t in e.tags) {
    if (t.isNotEmpty && t[0] == 'a') {
      if (t.length < 2 || !_productCoord.hasMatch(t[1])) return false;
    }
  }
  return true;
}

/// Parse a kind-30405 into a category, or null if it is not ours.
NostrCategory? parseCategoryEvent(NostrEvent e, String merchantPubkey) {
  if (!isOurCollection(e, merchantPubkey)) return null;

  final productDs = <String>[];
  for (final t in e.tags) {
    if (t.isEmpty || t[0] != 'a' || t.length < 2) continue;
    if (!t[1].startsWith('$kindProduct:')) continue;
    final parts = t[1].split(':');
    if (parts.length >= 3 && parts[2].isNotEmpty) productDs.add(parts[2]);
  }

  final name = _tagValue(e, 'title')!;
  return NostrCategory(
    d: _tagValue(e, 'd')!,
    name: name,
    slug: slugify(_tagValue(e, 't') ?? name),
    emoji: _tagValue(e, 'icon'),
    order: int.tryParse(_tagValue(e, 'order') ?? '') ?? 0,
    productDs: productDs,
    updatedAt: e.createdAt,
  );
}

// ------------------------------------------------- addressability & deletion

/// `<kind>:<pubkey>:<d>` for an addressable event, else null.
String? coordinateOf(NostrEvent e) {
  if (e.kind < 30000 || e.kind >= 40000) return null;
  return '${e.kind}:${e.pubkey}:${_tagValue(e, 'd') ?? ''}';
}

/// Collect NIP-09 deletions as `coordinate -> newest deleting created_at`.
Map<String, int> buildDeletionIndex(Iterable<NostrEvent> events) {
  final out = <String, int>{};
  for (final e in events) {
    if (e.kind != kindDeletion) continue;
    for (final t in e.tags) {
      if (t.isEmpty || t[0] != 'a' || t.length < 2) continue;
      final parts = t[1].split(':');
      // NIP-09 makes this a client MUST: nobody deletes anyone else's events,
      // and a hostile relay can put any kind-5 it likes into our subscription.
      if (parts.length < 2 || parts[1] != e.pubkey) continue;
      if (e.createdAt > (out[t[1]] ?? 0)) out[t[1]] = e.createdAt;
    }
  }
  return out;
}

bool isDeleted(NostrEvent e, Map<String, int> deletions) {
  final coord = coordinateOf(e);
  if (coord == null) return false;
  // `>=`, not `>`: a deletion covers everything up to AND INCLUDING its own
  // created_at, so a strictly later republish legitimately resurrects it.
  return (deletions[coord] ?? -1) >= e.createdAt;
}

/// Keep only the live version of each addressable event.
List<NostrEvent> latestByAddress(Iterable<NostrEvent> events) {
  final best = <String, NostrEvent>{};
  for (final e in events) {
    final coord = coordinateOf(e);
    if (coord == null) continue;
    final current = best[coord];
    if (current == null || _outranks(e, current)) best[coord] = e;
  }
  return best.values.toList();
}

/// Newest wins; ties break to the LOWEST id. NIP-01 calls that tiebreak a
/// convention implementations "may vary" on, so we apply it ourselves instead
/// of trusting whichever relay happened to answer first.
bool _outranks(NostrEvent a, NostrEvent b) {
  if (a.createdAt != b.createdAt) return a.createdAt > b.createdAt;
  return (a.id ?? a.computedId).compareTo(b.id ?? b.computedId) < 0;
}

// -------------------------------------------------------------------- groups

@immutable
class CategoryGroup {
  /// null = the uncategorised bucket.
  final NostrCategory? category;
  final List<NostrProduct> products;
  const CategoryGroup(this.category, this.products);
}

/// Arrange the catalog into the sections a menu renders.
///
/// `t` (the slug) is authoritative for MEMBERSHIP; a category's `a` list only
/// orders products WITHIN its group. Drift between the two therefore costs
/// ordering, never a product disappearing.
List<CategoryGroup> groupCatalog(
  List<NostrProduct> products,
  List<NostrCategory> categories,
) {
  final sorted = [...categories]..sort((a, b) {
      final byOrder = a.order.compareTo(b.order);
      return byOrder != 0
          ? byOrder
          : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

  // One section per slug, newest wins — it is the one being edited. Without
  // this, a merchant who deleted "Comida" and recreated it saw the section
  // twice with every item duplicated inside it.
  final bySlug = <String, NostrCategory>{};
  for (final c in sorted) {
    final existing = bySlug[c.slug];
    if (existing == null || c.updatedAt > existing.updatedAt) bySlug[c.slug] = c;
  }

  final grouped = <String, List<NostrProduct>>{};
  final uncategorised = <NostrProduct>[];
  for (final p in products) {
    // The FIRST slug the merchant actually has a category for wins; that is the
    // primary category, and tag order is what encodes priority.
    String? primary;
    for (final s in p.categorySlugs) {
      if (bySlug.containsKey(s)) {
        primary = s;
        break;
      }
    }
    if (primary == null) {
      uncategorised.add(p);
    } else {
      grouped.putIfAbsent(primary, () => []).add(p);
    }
  }

  final groups = <CategoryGroup>[];
  for (final c in sorted) {
    // Skip the losers of a slug collision, or their products render twice.
    if (!identical(bySlug[c.slug], c)) continue;
    final list = grouped[c.slug];
    if (list == null || list.isEmpty) continue;

    final rank = <String, int>{
      for (var i = 0; i < c.productDs.length; i++) c.productDs[i]: i,
    };
    list.sort((a, b) {
      final ra = rank[a.d] ?? 1 << 30;
      final rb = rank[b.d] ?? 1 << 30;
      return ra != rb
          ? ra.compareTo(rb)
          : a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    groups.add(CategoryGroup(c, list));
  }

  if (uncategorised.isNotEmpty) {
    uncategorised
        .sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    groups.add(CategoryGroup(null, uncategorised));
  }
  return groups;
}

// ---------------------------------------------------------------- projection

@immutable
class CatalogProjection {
  final List<Product> products;
  final List<({int id, String name})> categories;

  /// Published products this till cannot ring up: no price, a currency we
  /// cannot convert, or a recurring subscription price. Surfaced in the UI —
  /// silently shrinking a merchant's menu turns a loud money bug into a quiet
  /// inventory one.
  final int unsellable;

  const CatalogProjection({
    required this.products,
    required this.categories,
    required this.unsellable,
  });

  bool get isEmpty => products.isEmpty;
}

/// Can this product be charged at a till?
bool _isSellable(NostrProduct p) {
  final price = p.price;
  if (price == null) return false; // NIP-99 says price is SHOULD, not MUST
  if (price.frequency != null) return false; // a subscription, not a sale
  if (price.amount <= 0) return false;
  return CurrencyX.tryFromCode(price.currency) != null;
}

/// Turn raw relay events into the menu, as seen by [merchantPubkey].
///
/// Product and category ids are LIST INDICES. The reference derives them from
/// sha256(d) because its consumer needs ids stable across fetches; nothing here
/// does — they never leave the menu screen, and `OrderItem` carries name, price
/// and quantity, not an id.
///
/// ponytail: index ids change on every refresh. That is only safe because the
/// menu screen holds a refresh while the cart is non-empty. Derive from `d`
/// (see the reference's pos-id.ts) if an id ever needs to outlive a fetch.
CatalogProjection buildCatalog(
  Iterable<NostrEvent> events,
  String merchantPubkey,
) {
  // `authors:` in a REQ is a request, not a guarantee.
  final own = events.where((e) => e.pubkey == merchantPubkey).toList();

  final deletions = buildDeletionIndex(own);
  final addressable = latestByAddress(
    own.where((e) => e.kind >= 30000 && !isDeleted(e, deletions)),
  );

  final categories = <NostrCategory>[];
  final sellable = <NostrProduct>[];
  var unsellable = 0;

  for (final e in addressable) {
    if (e.kind == kindCategory) {
      final c = parseCategoryEvent(e, merchantPubkey);
      if (c != null) categories.add(c);
      continue;
    }
    if (e.kind != kindProduct) continue;

    final p = parseProductEvent(e);
    if (p == null) continue;
    // Merchant intent, not a defect — these are not counted as unsellable.
    if (p.status != 'active' || p.visibility == 'hidden') continue;

    if (_isSellable(p)) {
      sellable.add(p);
    } else {
      unsellable++;
    }
  }

  final groups = groupCatalog(sellable, categories);

  final products = <Product>[];
  final cats = <({int id, String name})>[];
  for (final g in groups) {
    // The uncategorised bucket keeps id 0 and is deliberately absent from
    // `cats`, so the menu screen's existing `catName[id] ?? tr('Otros')`
    // fallback names and translates it.
    final categoryId = g.category == null ? 0 : cats.length + 1;
    if (g.category != null) {
      cats.add((id: categoryId, name: g.category!.name));
    }
    for (final p in g.products) {
      products.add(Product(
        id: products.length + 1,
        categoryId: categoryId,
        name: p.title,
        description: p.description,
        priceValue: p.price!.amount,
        priceCurrency: CurrencyX.tryFromCode(p.price!.currency)!,
        imageUrls: p.imageUrls,
      ));
    }
  }

  return CatalogProjection(
    products: products,
    categories: cats,
    unsellable: unsellable,
  );
}

/// The events worth replicating to other relays: the CURRENT catalog plus the
/// deletions that shape it.
///
/// Deliberately NOT every event ever fetched. Addressable events are versioned
/// — a product repriced ten times has ten events on the wire, all validly
/// signed — and pushing the superseded ones to a relay that had correctly
/// dropped them re-litigates history for no benefit, multiplying the traffic by
/// however long the merchant has been trading.
///
/// Deletions ARE included: propagating them is the whole point, since a relay
/// missing a kind-5 keeps serving a product the merchant removed.
List<NostrEvent> liveEventsFor(
  Iterable<NostrEvent> events,
  String merchantPubkey,
) {
  final own = events.where((e) => e.pubkey == merchantPubkey).toList();
  final deletions = buildDeletionIndex(own);
  final live = latestByAddress(
    own.where((e) => e.kind >= 30000 && !isDeleted(e, deletions)),
  );
  return [
    ...live,
    ...own.where((e) => e.kind == kindDeletion),
  ];
}
