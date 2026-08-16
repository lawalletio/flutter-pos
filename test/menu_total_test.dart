import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/data/pricing/pricing_service.dart';
import 'package:lawallet_pos/domain/config/currencies.dart';
import 'package:lawallet_pos/domain/order/product.dart';

/// The cart total. This is the money path: every case here is an amount a
/// customer would actually be charged.

Product p(num value, Currency currency) => Product(
      id: value.hashCode ^ currency.index,
      categoryId: 1,
      name: '$currency $value',
      description: '',
      priceValue: value,
      priceCurrency: currency,
    );

void main() {
  // 0.5 ARS per sat, 0.0005 USD per sat.
  final rates = PricingService()..seedRates(const Rates(0.5, 0.0005));

  test('mixed currencies are summed per currency, never as one number', () {
    final lines = [
      CartLine(p(21000, Currency.ars)), // -> 42000 sats
      CartLine(p(25, Currency.usd)), //    -> 50000 sats
    ];

    final total = cartTotalSats(lines, rates.fiatToSats);

    expect(total, 42000 + 50000);
    // The bug this replaced: summing 21000 + 25 and converting the lot as ARS.
    // The bundled menus really did price books in USD beside ARS drinks, so
    // this was a live ~1000x undercharge on the USD line — and a nostr catalog
    // can mix currencies just as freely.
    expect(total, isNot(rates.fiatToSats(21025, Currency.ars)));
  });

  test('quantities multiply before conversion', () {
    final line = CartLine(p(1000, Currency.ars), 3);
    expect(cartTotalSats([line], rates.fiatToSats), 6000);
  });

  test('a SAT-priced cart needs no rates at all', () {
    final noRates = PricingService();
    expect(
      cartTotalSats([CartLine(p(1234, Currency.sat))], noRates.fiatToSats),
      1234,
    );
  });

  test('a missing rate blocks the charge instead of undercharging', () {
    final noRates = PricingService();
    final lines = [
      CartLine(p(1000, Currency.sat)), // convertible
      CartLine(p(500, Currency.ars)), // not, without rates
    ];

    // Returning 1000 here — the convertible part — would quietly drop the ARS
    // line from the bill. The button is disabled on null instead.
    expect(cartTotalSats(lines, noRates.fiatToSats), isNull);
  });

  test('an empty cart is zero, not null', () {
    expect(cartTotalSats(const [], rates.fiatToSats), 0);
  });

  test('Product.fromJson keeps the currency it was given', () {
    final usd = Product.fromJson({
      'id': 1,
      'category_id': 1,
      'name': 'Criptoria',
      'price': {'value': 25, 'currency': 'USD'},
    });
    expect(usd.priceCurrency, Currency.usd);

    // Our own bundled assets: an unreadable code is our bug, not hostile input,
    // so this path keeps the historical ARS default rather than dropping a line.
    final weird = Product.fromJson({
      'id': 2,
      'category_id': 1,
      'name': '?',
      'price': {'value': 1, 'currency': 'EUR'},
    });
    expect(weird.priceCurrency, Currency.ars);
  });

  test('a Product round-trips through the cache shape', () {
    final original = p(25, Currency.usd);
    final restored = Product.fromJson(original.toJson());
    expect(restored.priceValue, 25);
    expect(restored.priceCurrency, Currency.usd);
  });
}
