import '../config/currencies.dart';

/// Product catalog model. Mirrors the webapp menu JSON schema
/// (`src/constants/menus/*.json`), which is also the shape the nostr NIP-99
/// catalog is projected into and the shape the offline cache stores.
class Product {
  final int id;
  final int categoryId;
  final String name;
  final String description;
  final num priceValue;
  final Currency priceCurrency;

  /// NIP-99 `image` tag URLs, in tag order. Carried so the data survives a
  /// cache round-trip; nothing renders them yet.
  final List<String> imageUrls;

  /// The NIP-99 `d` tag this product was projected from. Empty for anything not
  /// backed by a catalog event. Coupons scoped to products match on this — [id]
  /// cannot serve, since it is a position in the current projection and moves
  /// whenever the catalog does.
  final String d;

  const Product({
    required this.id,
    required this.categoryId,
    required this.name,
    required this.description,
    required this.priceValue,
    required this.priceCurrency,
    this.imageUrls = const [],
    this.d = '',
  });

  factory Product.fromJson(Map<String, dynamic> j) {
    final price = (j['price'] as Map?) ?? const {};
    return Product(
      id: (j['id'] as num).toInt(),
      categoryId: (j['category_id'] as num?)?.toInt() ?? 0,
      name: j['name'] as String,
      description: (j['description'] as String?) ?? '',
      priceValue: (price['value'] as num?) ?? 0,
      // This path reads files we ship and a cache we wrote, so an unreadable
      // code means a bug on our side, not hostile input — keep the historical
      // ARS default rather than silently dropping the line. Relay data goes
      // through `parsePriceTag` + `tryFromCode` instead, which refuse.
      priceCurrency:
          CurrencyX.tryFromCode((price['currency'] as String?) ?? 'ARS') ??
              Currency.ars,
      imageUrls: [
        for (final u in (j['images'] as List?) ?? const []) u.toString(),
      ],
      d: (j['d'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'category_id': categoryId,
        'name': name,
        'description': description,
        'price': {'value': priceValue, 'currency': priceCurrency.code},
        if (imageUrls.isNotEmpty) 'images': imageUrls,
        if (d.isNotEmpty) 'd': d,
      };
}

class CartLine {
  final Product product;
  int qty;
  CartLine(this.product, [this.qty = 1]);

  num get subtotal => product.priceValue * qty;
}

/// Total of [lines] in whole satoshis, or null if it cannot be known.
///
/// Sums **per currency** and converts each sum once. Never sum across
/// currencies. The bundled menus this app used to ship priced books and a
/// terminal in USD beside ARS drinks, and adding 25 (USD) to 21000 (ARS) as
/// though both were pesos undercharged the USD line by roughly a factor of a
/// thousand — which is exactly what this app did before this function existed.
/// A nostr catalog can mix currencies just as freely. Summing per currency
/// also beats converting line by line, which accumulates up to half a sat of
/// rounding error per line.
///
/// Returns null when any currency present has no rate loaded yet. A missing
/// rate must block the charge: dropping that currency's subtotal and charging
/// the rest would silently undercharge the order.
int? cartTotalSats(
  Iterable<CartLine> lines,
  int? Function(num amount, Currency currency) toSats,
) {
  final byCurrency = <Currency, num>{};
  for (final l in lines) {
    byCurrency.update(
      l.product.priceCurrency,
      (sum) => sum + l.subtotal,
      ifAbsent: () => l.subtotal,
    );
  }

  var total = 0;
  for (final entry in byCurrency.entries) {
    final sats = toSats(entry.value, entry.key);
    if (sats == null) return null;
    total += sats;
  }
  return total;
}
