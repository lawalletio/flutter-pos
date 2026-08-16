import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/domain/config/currencies.dart';
import 'package:lawallet_pos/domain/coupon/coupon.dart';
import 'package:lawallet_pos/domain/order/current_order.dart';

/// What a coupon takes off the bill. Every number here is money a customer is
/// or isn't charged, so the cases are the ones from the merchant spec, run
/// against the same basket it uses.

const empanadaD = '11111111-1111-4111-8111-111111111111';
const cafeD = '22222222-2222-4222-8222-222222222222';
const remeraD = '33333333-3333-4333-8333-333333333333';

/// 2 × empanada ARS 100 + 1 × café ARS 250 = ARS 450 bruto.
final basket = [
  const OrderItem(
      name: 'Empanada', unitPrice: 100, qty: 2, d: empanadaD, currency: Currency.ars),
  const OrderItem(
      name: 'Café', unitPrice: 250, qty: 1, d: cafeD, currency: Currency.ars),
];

/// 2 ARS per sat, 0.0005 USD per sat.
int? rates(num amount, Currency c) => switch (c) {
      Currency.sat => amount.round(),
      Currency.ars => (amount / 2).round(),
      Currency.usd => (amount / 0.0005).round(),
    };

int? noRates(num amount, Currency c) => c == Currency.sat ? amount.round() : null;

Benefit parse(Map<String, dynamic> json) {
  final p = parseBenefit(json);
  expect(p.reason, isNull, reason: 'no parseó: ${p.reason}');
  return p.value!;
}

CouponQuote quote(Map<String, dynamic> json,
        {List<OrderItem>? lines,
        int? goods,
        int? Function(num, Currency)? toSats}) =>
    quoteCoupon(
      benefit: parse(json),
      goodsSats: goods ?? 225, // ARS 450 a 2 ARS/sat
      lines: lines ?? basket,
      toSats: toSats ?? rates,
    );

void main() {
  group('la tabla de la spec, sobre ARS 450', () {
    test('percent 10% descuenta 45', () {
      expect(quote({'type': 'percent', 'percent': 10}).entries.single.amount, 45);
    });

    test('el cap manda sobre los términos', () {
      final q = quote({
        'type': 'percent',
        'percent': 10,
        'cap': {'amount': 20, 'currency': 'ARS'},
      });
      expect(q.entries.single.amount, 20);
      expect(q.discountSats, 10);
    });

    test('fixed por encima del total se clampea a la canasta, nunca negativo', () {
      final q = quote({'type': 'fixed', 'amount': 500, 'currency': 'ARS'});
      expect(q.discountSats, 225); // los 225 sats que vale la canasta, no 250
    });

    test('fixed con alcance se clampea a lo que valen ESOS productos', () {
      // ARS 500 sobre café: el café vale 250, y el descuento no puede
      // derramarse sobre las empanadas que el cupón no nombra.
      final q = quote({
        'type': 'fixed',
        'amount': 500,
        'currency': 'ARS',
        'productDs': [cafeD],
      });
      expect(q.entries.single.amount, 250);
    });

    test('multibuy 2x1 en empanada regala una', () {
      final q = quote({
        'type': 'multibuy',
        'buyQty': 2,
        'payQty': 1,
        'productDs': [empanadaD],
      });
      expect(q.freeUnits.single.qty, 1);
      expect(q.entries.single.amount, 100);
    });

    test('buyXgetY regala el café', () {
      final q = quote({
        'type': 'buyXgetY',
        'buyProductD': empanadaD,
        'giftProductD': cafeD,
      });
      expect(q.entries.single.amount, 250);
    });

    test('freeItems regala solo las unidades que están en la canasta', () {
      // El cupón dice 3 empanadas y hay 2: se regalan 2. Regalar la tercera
      // sería descontar un producto que nadie pidió.
      final q = quote({
        'type': 'freeItems',
        'items': [
          {'d': empanadaD, 'qty': 3}
        ],
      });
      expect(q.freeUnits.single.qty, 2);
      expect(q.entries.single.amount, 200);
    });
  });

  group('lo que NO se descuenta', () {
    test('un cupón para un producto ausente no aplica, y dice por qué', () {
      final q = quote({
        'type': 'percent',
        'percent': 50,
        'productDs': [remeraD],
      });
      expect(q.applies, isFalse);
      expect(q.discountSats, 0);
      expect(q.unmet!.message, isNotEmpty);
    });

    test('la canasta de Caja registradora no tiene d: los cupones con alcance no aplican', () {
      final paydesk = [
        const OrderItem(name: 'Cobro', unitPrice: 5000, qty: 1, currency: Currency.sat),
      ];
      expect(
        quote({'type': 'percent', 'percent': 10, 'productDs': [cafeD]},
                lines: paydesk, goods: 5000)
            .applies,
        isFalse,
      );
      // ...pero un porcentaje sin alcance sí.
      expect(
        quote({'type': 'percent', 'percent': 10}, lines: paydesk, goods: 5000)
            .discountSats,
        500,
      );
    });

    test('sin cotización el cupón no aplica en vez de descontar cero en silencio', () {
      // Descontar 0 haría que la pantalla diga "cupón aplicado" y cobre el
      // precio entero: peor que negarlo, porque nadie lo mira dos veces.
      final q = quote({'type': 'percent', 'percent': 10}, toSats: noRates);
      expect(q.applies, isFalse);
      expect(q.unmet!.message, contains('ARS'));
    });

    test('buyXgetY del mismo producto necesita dos: uno solo ES el regalo', () {
      final uno = [
        const OrderItem(
            name: 'Café', unitPrice: 250, qty: 1, d: cafeD, currency: Currency.ars),
      ];
      expect(
        quote({'type': 'buyXgetY', 'buyProductD': cafeD, 'giftProductD': cafeD},
                lines: uno, goods: 125)
            .applies,
        isFalse,
      );
    });
  });

  test('el descuento puede llegar a cero, y ahí no hay factura', () {
    final q = quote({'type': 'percent', 'percent': 100});
    expect(q.discountSats, 225);
    expect(225 - q.discountSats, 0);
  });

  test('la propina nunca queda descontada', () {
    // Se cobran 300 sats: 225 de canasta + 75 de propina. Un 100% off tiene que
    // dejar la propina intacta.
    final q = quote({'type': 'percent', 'percent': 100}, goods: 225);
    expect(300 - q.discountSats, 75);
  });

  test('en una canasta multi-moneda cada moneda se descuenta por separado', () {
    final mixta = [
      const OrderItem(
          name: 'Café', unitPrice: 250, qty: 1, d: cafeD, currency: Currency.ars),
      const OrderItem(
          name: 'Remera', unitPrice: 20, qty: 1, d: remeraD, currency: Currency.usd),
    ];
    // ARS 250 → 125 sats, USD 20 → 40000 sats. Bruto 40125.
    final q = quote({'type': 'percent', 'percent': 10}, lines: mixta, goods: 40125);
    expect(q.entries.length, 2);
    // 25 ARS (12.5 → 13 sats) + 2 USD (4000 sats). Sumar 250+20 como si fueran
    // una sola moneda daría 27, un descuento ~150x más chico.
    expect(q.discountSats, 13 + 4000);
  });
}
