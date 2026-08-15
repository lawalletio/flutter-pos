import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/domain/config/currencies.dart';
import 'package:lawallet_pos/domain/order/current_order.dart';
import 'package:lawallet_pos/domain/order/orders_store.dart';
import 'package:lawallet_pos/features/payment/coupon_scan_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const nonce = 'AbCdEfGhIjKlMnOpQrStUv';
const cafeD = '22222222-2222-4222-8222-222222222222';

OrderRecord withCoupon({String id = 'o1', bool isPaid = false}) => OrderRecord(
      id: id,
      createdAt: 1750000000000,
      amountSats: 405,
      summary: '1× Café',
      isPaid: isPaid,
      items: const [
        OrderItem(name: 'Café', unitPrice: 250, qty: 1, d: cafeD, currency: Currency.ars),
      ],
      couponId: 'c-1',
      couponName: 'Bienvenida',
      couponNonce: nonce,
      discountSats: 45,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('el cupón sobrevive el guardado', () {
    test('round-trip por el shape persistido', () {
      final back = OrderRecord.fromJson(withCoupon().toJson());
      expect(back.couponName, 'Bienvenida');
      expect(back.couponNonce, nonce);
      expect(back.discountSats, 45);
      expect(back.grossSats, 450);
      expect(back.items.single.d, cafeD);
      expect(back.items.single.currency, Currency.ars);
    });

    test('markPaid no pierde el cupón', () async {
      // El copyWith copiaba campo por campo a mano: lo que no estuviera ahí
      // desaparecía en silencio, y la reimpresión salía sin el cupón.
      SharedPreferences.setMockInitialValues({});
      final store = OrdersStore();
      await store.upsert(withCoupon());
      await store.markPaid('o1');

      final saved = store.notifier.value.single;
      expect(saved.isPaid, isTrue);
      expect(saved.couponName, 'Bienvenida');
      expect(saved.discountSats, 45);
      expect(saved.items.single.name, 'Café');
    });

    test('upsert reemplaza la orden re-cotizada en vez de duplicarla', () async {
      // Aplicar un cupón vuelve a cotizar la orden. Un segundo `add` dejaría la
      // pendiente a precio lleno en la lista para siempre.
      SharedPreferences.setMockInitialValues({});
      final store = OrdersStore();
      await store.upsert(OrderRecord(
          id: 'o1', createdAt: 1, amountSats: 450, summary: '1× Café'));
      await store.upsert(withCoupon());

      expect(store.notifier.value.length, 1);
      expect(store.notifier.value.single.amountSats, 405);
    });

    test('una orden vieja sin campos de cupón se sigue leyendo', () {
      final legacy = OrderRecord.fromJson({
        'id': 'o0',
        'createdAt': 1,
        'amountSats': 100,
        'summary': 'x',
        'items': [
          {'name': 'Café', 'unitPrice': 250, 'qty': 1}
        ],
      });
      expect(legacy.discountSats, 0);
      expect(legacy.hasCoupon, isFalse);
      // Sin moneda guardada: ARS, que es lo que toda línea vieja era.
      expect(legacy.items.single.priceCurrency, Currency.ars);
    });
  });

  group('el QR escaneado', () {
    test('acepta el nonce pelado y el link que lo lleva', () {
      expect(nonceFromScan(nonce), nonce);
      expect(nonceFromScan('  $nonce  '), nonce);
      expect(nonceFromScan('https://tienda.ar/checkout?coupon=$nonce'), nonce);
      expect(nonceFromScan('https://tienda.ar/?a=1&coupon=$nonce&b=2'), nonce);
    });

    test('rechaza cualquier otra cosa antes de gastar un pedido', () {
      expect(nonceFromScan('lnbc1...'), isNull);
      expect(nonceFromScan('https://tienda.ar/checkout'), isNull);
      expect(nonceFromScan('https://tienda.ar/?coupon=corto'), isNull);
      expect(nonceFromScan(''), isNull);
      expect(nonceFromScan(null), isNull);
    });
  });
}
