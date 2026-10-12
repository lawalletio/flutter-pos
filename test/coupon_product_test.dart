import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/data/nostr/catalog.dart';
import 'package:lawallet_pos/data/nostr/event.dart';
import 'package:lawallet_pos/domain/config/currencies.dart';
import 'package:lawallet_pos/domain/coupon/coupon.dart';
import 'package:lawallet_pos/domain/order/current_order.dart';
import 'package:lawallet_pos/domain/order/product.dart';

/// Coupon products: a catalog product that carries a coupon, applied by ringing
/// it up. "Vaso" at price 0 with 5% off two drinks is the case from the panel.

final merchant = 'a' * 64;
const vasoD = '11111111-1111-4111-8111-111111111111';
const cervezaD = '22222222-2222-4222-8222-222222222222';
const fernetD = '33333333-3333-4333-8333-333333333333';
const empanadaD = '44444444-4444-4444-8444-444444444444';
const couponId = '55555555-5555-4555-8555-555555555555';

const fivePercentOnDrinks = {
  'type': 'percent',
  'percent': 5,
  'productDs': [cervezaD, fernetD],
};

NostrEvent product(String d, List<List<String>> extra) => NostrEvent(
      pubkey: merchant,
      createdAt: 1000,
      kind: kindProduct,
      content: '',
      tags: [
        ['d', d],
        ['title', d],
        ...extra,
      ],
    );

CatalogProjection catalogOf(List<NostrEvent> events) =>
    buildCatalog(events, merchant);

/// 2 ARS per sat.
int? rates(num amount, Currency c) =>
    c == Currency.sat ? amount.round() : (amount / 2).round();

void main() {
  group('the coupon and max_qty tags', () {
    test('a valid tag rides into the menu, price 0 included', () {
      final c = catalogOf([
        product(vasoD, [
          ['price', '0', 'ARS'],
          ['coupon', couponId, 'Vaso', jsonEncode(fivePercentOnDrinks)],
          ['max_qty', '2'],
        ]),
      ]);
      final p = c.products.single;
      expect(p.priceValue, 0);
      expect(p.coupon!.id, couponId);
      expect(p.coupon!.name, 'Vaso');
      expect(p.coupon!.benefit.percent, 5);
      expect(p.coupon!.benefit.productDs, [cervezaD, fernetD]);
      expect(p.maxQty, 2);
    });

    test('unreadable JSON or benefit: no coupon, the product still sells', () {
      final c = catalogOf([
        product(cervezaD, [
          ['price', '1000', 'ARS'],
          ['coupon', couponId, 'Rota', '{not json'],
        ]),
        product(fernetD, [
          ['price', '2000', 'ARS'],
          ['coupon', couponId, 'Cero', jsonEncode({'type': 'percent', 'percent': 0})],
        ]),
      ]);
      expect(c.products, hasLength(2));
      expect(c.products.every((p) => p.coupon == null), isTrue);
    });

    test('price 0 sells ONLY with a valid coupon', () {
      final c = catalogOf([
        product(vasoD, [
          ['price', '0', 'ARS'],
        ]),
        product(empanadaD, [
          ['price', '0', 'ARS'],
          ['coupon', couponId, 'Rota', '{not json'],
        ]),
      ]);
      expect(c.products, isEmpty);
      expect(c.unsellable, 2);
    });

    test('max_qty that is not a positive integer means unlimited', () {
      for (final raw in ['0', '-1', 'dos', '1.5']) {
        final c = catalogOf([
          product(cervezaD, [
            ['price', '1000', 'ARS'],
            ['max_qty', raw],
          ]),
        ]);
        expect(c.products.single.maxQty, isNull, reason: raw);
      }
    });

    test('coupon and max_qty survive the offline cache', () {
      final p = catalogOf([
        product(vasoD, [
          ['price', '0', 'ARS'],
          ['coupon', couponId, 'Vaso', jsonEncode(fivePercentOnDrinks)],
          ['max_qty', '1'],
        ]),
      ]).products.single;
      final back = Product.fromJson(
          jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(back.coupon!.id, couponId);
      expect(back.coupon!.benefit.productDs, [cervezaD, fernetD]);
      expect(back.maxQty, 1);
    });
  });

  group('stacking', () {
    // Vaso 0 + 2 × cerveza ARS 1000 + fernet ARS 2000 + empanada ARS 500
    // = ARS 4500 = 2250 sats.
    const lines = [
      OrderItem(name: 'Vaso', unitPrice: 0, qty: 1, d: vasoD, currency: Currency.ars),
      OrderItem(name: 'Cerveza', unitPrice: 1000, qty: 2, d: cervezaD, currency: Currency.ars),
      OrderItem(name: 'Fernet', unitPrice: 2000, qty: 1, d: fernetD, currency: Currency.ars),
      OrderItem(name: 'Empanada', unitPrice: 500, qty: 1, d: empanadaD, currency: Currency.ars),
    ];
    const goods = 2250;

    CouponQuote q(Map<String, dynamic> benefit, [List<OrderItem> ls = lines]) =>
        quoteCoupon(
          benefit: parseBenefit(benefit).value!,
          goodsSats: goods,
          lines: ls,
          toSats: rates,
        );

    test('the product 5% on the drinks plus a scanned fixed add up', () {
      final product = q(fivePercentOnDrinks); // 5% of ARS 4000 = ARS 200
      final scanned = q({'type': 'fixed', 'amount': 300, 'currency': 'ARS'});
      final s = stackQuotes([product, scanned], goodsSats: goods);
      expect(product.discountSats, 100);
      expect(scanned.discountSats, 150);
      expect(s.discountSats, 250);
      expect(s.entries.single.currency, Currency.ars);
      expect(s.entries.single.amount, 500);
    });

    test('two percents on the same line add, they do not compound', () {
      final s = stackQuotes([
        q(fivePercentOnDrinks),
        q({'type': 'percent', 'percent': 10, 'productDs': [cervezaD, fernetD]}),
      ], goodsSats: goods);
      expect(s.entries.single.amount, 600); // 15% of ARS 4000
    });

    test('the sum is clamped to the goods, never past them', () {
      final s = stackQuotes([
        q(fivePercentOnDrinks),
        q({'type': 'percent', 'percent': 100}),
      ], goodsSats: goods);
      expect(s.discountSats, goods);
    });

    test('Vaso without drinks contributes nothing, and is not an error', () {
      const onlyEmpanada = [
        OrderItem(name: 'Vaso', unitPrice: 0, qty: 1, d: vasoD, currency: Currency.ars),
        OrderItem(name: 'Empanada', unitPrice: 500, qty: 1, d: empanadaD, currency: Currency.ars),
      ];
      final product = q(fivePercentOnDrinks, onlyEmpanada);
      expect(product.applies, isFalse);
      final scanned = q({'type': 'fixed', 'amount': 100, 'currency': 'ARS'}, onlyEmpanada);
      final s = stackQuotes([product, scanned], goodsSats: 250);
      expect(s.discountSats, 50);
      expect(s.entries.single.amount, 100);
    });
  });
}
