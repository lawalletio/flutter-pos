import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/domain/order/current_order.dart';
import 'package:lawallet_pos/domain/order/orders_store.dart';
import 'package:lawallet_pos/features/payment/payment_screen.dart';

void main() {
  test('OrderRecord round-trips items + recheck fields through JSON', () {
    const rec = OrderRecord(
      id: 'o1',
      createdAt: 1783045050319,
      amountSats: 2500,
      summary: '2× Coca, 1× Café',
      verifyUrl: 'https://host/verify/abc',
      invoice: 'lnbc25',
      zapPubkey: 'deadbeef',
      zapRelays: ['wss://r1', 'wss://r2'],
      zapOrderId: 'e123',
      items: [
        OrderItem(name: 'Coca', unitPrice: 1500, qty: 2),
        OrderItem(name: 'Café', unitPrice: 1200, qty: 1),
      ],
    );

    // Encode + decode exactly as the store persists (jsonEncode of toJson).
    final back = OrderRecord.fromJson(
        jsonDecode(jsonEncode(rec.toJson())) as Map<String, dynamic>);

    expect(back.items.length, 2);
    expect(back.items[0].name, 'Coca');
    expect(back.items[0].unitPrice, 1500);
    expect(back.items[0].qty, 2);
    expect(back.items[1].name, 'Café');
    expect(back.verifyUrl, 'https://host/verify/abc');
    expect(back.invoice, 'lnbc25');
    expect(back.supportsLud21, isTrue);
    expect(back.supportsNip57, isTrue);
    expect(back.canRecheck, isTrue);
  });

  test('legacy record without items decodes to an empty item list', () {
    final back = OrderRecord.fromJson(const {
      'id': 'o2',
      'createdAt': 1,
      'amountSats': 100,
      'summary': 'x',
      'isPaid': false,
    });
    expect(back.items, isEmpty);
    expect(back.canRecheck, isFalse);
  });
  test('a rechecked order replays the paid flow with its own tip and gross',
      () {
    const rec = OrderRecord(
      id: 'o3',
      createdAt: 1,
      amountSats: 900, // net of the coupon, tip included
      summary: 'x',
      discountSats: 100,
      tipSats: 50,
    );
    final back = OrderRecord.fromJson(
        jsonDecode(jsonEncode(rec.toJson())) as Map<String, dynamic>);
    expect(back.tipSats, 50);

    final screen = PaymentScreen.paid(back, back: '/orders');
    expect(screen.amountSats, 1000); // gross; the screen nets the discount
    expect(screen.tipSats, 50); // drives the tip-only wheel offer
    expect(screen.paidOrder, same(back));
  });
}
