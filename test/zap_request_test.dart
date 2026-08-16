import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/data/lnurl/lnurl_service.dart';
import 'package:lawallet_pos/data/nostr/signer.dart';
import 'package:lawallet_pos/domain/config/currencies.dart';
import 'package:lawallet_pos/domain/coupon/coupon.dart';
import 'package:lawallet_pos/domain/order/current_order.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The kind-9734 zap request. Its `p` is the merchant's own key, and getting
/// that wrong is what makes a sale invisible in their feed.

/// agustin@lacrypta.ar, from their NIP-05.
const merchant = '2ad91f1dca2dcd5fc89e7208d1e5059f0bac0870d63fc3bac21c7a9388fa18fd';

/// The `nostrPubkey` lacrypta.ar advertises on its lnurlp — the SERVICE key
/// that signs receipts. agustin@ and barra@ both return this exact value.
const provider = '79f00d3f5a19ec806189fcab03c1be4ff81d18ee4f653c88fac41fe03570f432';

const cafeD = '22222222-2222-4222-8222-222222222222';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('p names the merchant, never the provider that signs the receipt', () async {
    final e = await LnurlService().buildZapRequest(
      recipientPubkey: merchant,
      amountMsats: 1607000,
      relays: const ['wss://relay.lacrypta.ar'],
      orderId: 'abc123',
      lnurl: 'lnurl1dp68gurn8ghj7',
    );

    final p = e.tags.where((t) => t[0] == 'p').toList();
    // Exactly one, as NIP-57 requires.
    expect(p.length, 1);
    expect(p.single[1], merchant);
    // The regression: a custodial provider hands the same nostrPubkey to every
    // account, so this made every merchant's sales look like zaps to La Crypta.
    expect(p.single[1], isNot(provider));
  });

  test('it is a well-formed, signed 9734', () async {
    final e = await LnurlService().buildZapRequest(
      recipientPubkey: merchant,
      amountMsats: 1607000,
      relays: const ['wss://relay.lacrypta.ar', 'wss://nostr-pub.wellorder.net'],
      orderId: 'abc123',
    );

    expect(e.kind, 9734);
    expect(e.content, '');
    expect(verifyEvent(e), isTrue);
    expect(e.tags.firstWhere((t) => t[0] == 'amount')[1], '1607000');
    expect(e.tags.firstWhere((t) => t[0] == 'relays').sublist(1),
        ['wss://relay.lacrypta.ar', 'wss://nostr-pub.wellorder.net']);
    expect(e.tags.firstWhere((t) => t[0] == 'e')[1], 'abc123');
  });

  group('what the merchant panel reads back', () {
    // It queries `{kinds:[9735], "#p":[merchantPubkey]}` and then parses the
    // request out of the receipt's `description`, so these tags are the only
    // thing standing between a sale and an order row with no detail.
    Future<List<List<String>>> tagsFor(List<OrderItem> lines,
        {List<DiscountEntry> discounts = const [],
        String? couponId,
        String? couponName}) async {
      final e = await LnurlService().buildZapRequest(
        recipientPubkey: merchant,
        amountMsats: 1000,
        relays: const ['wss://relay.lacrypta.ar'],
        orderId: 'abc123',
        lines: lines,
        discounts: discounts,
        couponId: couponId,
        couponType: couponId == null ? null : 'percent',
        couponName: couponName,
      );
      return e.tags;
    }

    test('the basket travels as item/items_count/total tags', () async {
      final tags = await tagsFor(const [
        OrderItem(name: 'Café', unitPrice: 250, qty: 2, d: cafeD, currency: Currency.ars),
      ]);
      expect(tags.firstWhere((t) => t[0] == 'item'),
          ['item', cafeD, '2', '250', 'ARS']);
      expect(tags.firstWhere((t) => t[0] == 'items_count')[1], '2');
      expect(tags.firstWhere((t) => t[0] == 'total'), ['total', '500', 'ARS']);
    });

    test('gross and discount are separate, so the panel can show both', () async {
      final tags = await tagsFor(
        const [
          OrderItem(name: 'Café', unitPrice: 250, qty: 2, d: cafeD, currency: Currency.ars),
        ],
        discounts: const [DiscountEntry(Currency.ars, 50)],
        couponId: 'c-1',
        couponName: 'Bienvenida',
      );
      // 500 gross − 50 off = 450 charged. The net alone is indistinguishable
      // from a cheaper basket.
      expect(tags.firstWhere((t) => t[0] == 'total'), ['total', '500', 'ARS']);
      expect(tags.firstWhere((t) => t[0] == 'discount'), ['discount', '50', 'ARS']);
      expect(tags.firstWhere((t) => t[0] == 'coupon'),
          ['coupon', 'c-1', 'percent', 'Bienvenida']);
    });

    test('a paydesk charge invents no product', () async {
      final tags = await tagsFor(
        const [OrderItem(name: 'Cobro', unitPrice: 5000, qty: 1, currency: Currency.sat)],
      );
      expect(tags.where((t) => t[0] == 'item'), isEmpty);
      expect(tags.firstWhere((t) => t[0] == 'total'), ['total', '5000', 'SAT']);
    });

    test('a long basket sheds line detail rather than losing the invoice', () async {
      // The event is URL-encoded into the callback's query string; past a point
      // the provider rejects the GET and there is no invoice at all.
      final long = [
        for (var i = 0; i < 40; i++)
          OrderItem(
              name: 'Producto $i',
              unitPrice: 100,
              qty: 1,
              d: '${i.toString().padLeft(8, '0')}-2222-4222-8222-222222222222',
              currency: Currency.ars),
      ];
      final tags = await tagsFor(long);
      expect(tags.where((t) => t[0] == 'item'), isEmpty);
      // What the merchant is owed survives.
      expect(tags.firstWhere((t) => t[0] == 'total'), ['total', '4000', 'ARS']);
      expect(jsonEncode(tags).length, lessThan(1200));
    });
  });
}
