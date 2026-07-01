/// Product catalog model. Mirrors the webapp menu JSON schema
/// (`src/constants/menus/*.json`).
class Product {
  final int id;
  final int categoryId;
  final String name;
  final String description;
  final num priceValue;
  final String priceCurrency;

  const Product({
    required this.id,
    required this.categoryId,
    required this.name,
    required this.description,
    required this.priceValue,
    required this.priceCurrency,
  });

  factory Product.fromJson(Map<String, dynamic> j) {
    final price = (j['price'] as Map?) ?? const {};
    return Product(
      id: j['id'] as int,
      categoryId: (j['category_id'] as int?) ?? 0,
      name: j['name'] as String,
      description: (j['description'] as String?) ?? '',
      priceValue: (price['value'] as num?) ?? 0,
      priceCurrency: (price['currency'] as String?) ?? 'ARS',
    );
  }
}

class CartLine {
  final Product product;
  int qty;
  CartLine(this.product, [this.qty = 1]);

  num get subtotal => product.priceValue * qty;
}
