import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lawallet_pos/data/coupon/coupon_service.dart';
import 'package:lawallet_pos/data/nostr/coupon_events.dart';
import 'package:lawallet_pos/data/nostr/event.dart';
import 'package:lawallet_pos/data/nostr/signer.dart';
import 'package:lawallet_pos/domain/config/currencies.dart';
import 'package:lawallet_pos/domain/coupon/coupon.dart';
import 'package:lawallet_pos/domain/order/current_order.dart';

/// The claim client. The coupon endpoint answers for every merchant on the
/// deployment and 404s are routine, so the cases here are the ones where
/// believing the response would cost somebody money.

/// Replays a canned body without a socket.
class _Canned implements HttpClientAdapter {
  _Canned(this.status, this.body);
  final int status;
  final Object body;
  RequestOptions? seen;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? _, Future<void>? __) async {
    seen = options;
    return ResponseBody.fromString(jsonEncode(body), status,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }

  @override
  void close({bool force = false}) {}
}

const managerKey = '0000000000000000000000000000000000000000000000000000000000000001';
final managerPubkey = derivePublicKey(managerKey);

// agustin@lacrypta.ar, and its npub.
const merchantHex = '2ad91f1dca2dcd5fc89e7208d1e5059f0bac0870d63fc3bac21c7a9388fa18fd';
const merchantNpub = 'npub19tv378w29hx4ljy7wgydreg9nu96czrs6clu8wkzr3af8z86rr7sujx4xe';

/// merch@lacrypta.ar — un comercio real distinto, en el mismo deployment.
const otherNpub = 'npub13zpsfga2a45hur03ya6ngqmq0tjfftjzt445vplucz6cytpxmq2swfk89n';
const nonce = 'AbCdEfGhIjKlMnOpQrStUv';

Map<String, dynamic> payload({String? npub, String status = 'minted'}) => {
      'status': status,
      'couponId': 'c-1',
      'coupon': {'type': 'percent', 'percent': 10},
      'name': 'Bienvenida',
      'description': '10% en tu primera compra',
      'npub': npub ?? merchantNpub,
      'nonce': nonce,
      'expiresAt': null,
    };

void main() {
  // buildCouponOrder signs with the POS's own identity, which is persisted.
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  ({CouponService svc, _Canned net}) service(int status, Object body) {
    final net = _Canned(status, body);
    return (svc: CouponService(dio: Dio()..httpClientAdapter = net), net: net);
  }

  group('check (GET, no consume)', () {
    test('un cupón vivo del comercio correcto se acepta', () async {
      final s = service(200, payload());
      final info = await s.svc.check('https://m.ar/api/coupons/claim', nonce,
          merchantPubkey: merchantHex);
      expect(info.isRedeemable, isTrue);
      expect(info.benefit.percent, 10);
      expect(s.net.seen!.method, 'GET');
      expect(s.net.seen!.uri.queryParameters['nonce'], nonce);
    });

    test('un cupón de OTRO comercio se rechaza', () async {
      // Un deployment sirve a muchos comercios y responde por cualquier nonce
      // que conozca: sin este chequeo, un 50% de una tienda se gasta en la de
      // al lado.
      final s = service(200, payload(npub: otherNpub));
      await expectLater(
        s.svc.check('https://m.ar/api/coupons/claim', nonce,
            merchantPubkey: merchantHex),
        throwsA(isA<CouponException>().having(
            (e) => e.message, 'message', contains('otro comercio'))),
      );
    });

    test('ya usado / vencido / anulado llegan con su motivo, no como error', () async {
      for (final entry in {
        'claimed': 'ya fue usado',
        'expired': 'vencido',
        'voided': 'anulado',
      }.entries) {
        final s = service(200, payload(status: entry.key));
        final info = await s.svc.check('https://m.ar/c', nonce,
            merchantPubkey: merchantHex);
        expect(info.isRedeemable, isFalse);
        expect(info.statusReason, contains(entry.value));
      }
    });

    test('el 404 real del endpoint se muestra con las palabras del servidor', () async {
      final s = service(404, {'error': 'Cupón inexistente.'});
      await expectLater(
        s.svc.check('https://m.ar/c', nonce, merchantPubkey: merchantHex),
        throwsA(isA<CouponException>()
            .having((e) => e.message, 'message', 'Cupón inexistente.')),
      );
    });

    test('un nonce mal formado no gasta un pedido', () async {
      final s = service(200, payload());
      await expectLater(
        s.svc.check('https://m.ar/c', 'corto', merchantPubkey: merchantHex),
        throwsA(isA<CouponException>()),
      );
      expect(s.net.seen, isNull);
    });

    test('un beneficio ilegible se rechaza en vez de aplicarse a medias', () async {
      final body = payload()..['coupon'] = {'type': 'percent', 'percent': 500};
      final s = service(200, body);
      await expectLater(
        s.svc.check('https://m.ar/c', nonce, merchantPubkey: merchantHex),
        throwsA(isA<CouponException>()),
      );
    });
  });

  group('redeem (POST, consume)', () {
    CouponDiscovery discovery() => CouponDiscovery(
        managerPubkey: managerPubkey,
        mintUrl: 'https://m.ar/api/coupons/mint',
        claimUrl: 'https://m.ar/api/coupons/claim');

    Map<String, dynamic> voucherEvent({String? key, String? withNonce}) =>
        signEvent(
          NostrEvent(
            pubkey: '',
            createdAt: 1750000000,
            kind: kindCouponVoucher,
            tags: [
              ['nonce', withNonce ?? nonce]
            ],
            content: jsonEncode({
              'v': 1,
              'nonce': withNonce ?? nonce,
              'owner': merchantHex,
              'name': 'Bienvenida',
              'description': '10% en tu primera compra',
              'coupon': {'type': 'percent', 'percent': 10},
              'phase': 'claimed',
              'claimedAt': 1750000000,
            }),
          ),
          key ?? managerKey,
        ).toJson();

    test('success trae el voucher verificado y fresh en true', () async {
      final s = service(200, {
        ...payload(),
        'status': 'success',
        'claimedAt': 1750000000,
        'voucher': voucherEvent(),
      });
      final r = await s.svc.redeem(
        discovery: discovery(),
        nonce: nonce,
        merchantPubkey: merchantHex,
        amountMsat: 202500,
      );
      expect(r.fresh, isTrue);
      expect(r.voucher, isNotNull);
      expect(r.info.isRedeemable, isTrue);
      expect(s.net.seen!.method, 'POST');
      expect((s.net.seen!.data as Map)['amountMsat'], 202500);
    });

    test('claimed es 200 y NO es un error: es un reintento', () async {
      // Una POS que perdió la respuesta y reintenta tiene que poder distinguir
      // "lo canjeé yo" de "ya lo canjeó otro", y claimedAt es cómo.
      final s = service(200, {
        ...payload(),
        'status': 'claimed',
        'claimedAt': 1750000000,
        'voucher': voucherEvent(),
      });
      final r = await s.svc.redeem(
          discovery: discovery(),
          nonce: nonce,
          merchantPubkey: merchantHex,
          amountMsat: 0);
      expect(r.fresh, isFalse);
      expect(r.info.claimedAt, 1750000000);
    });

    test('un voucher firmado por otra clave se descarta, el canje sigue en pie', () async {
      // Negarle el cupón a alguien parado en el mostrador porque no pudimos
      // archivar el papeleo es el peor resultado posible.
      final s = service(200, {
        ...payload(),
        'status': 'success',
        'voucher': voucherEvent(
            key: '0000000000000000000000000000000000000000000000000000000000000002'),
      });
      final r = await s.svc.redeem(
          discovery: discovery(),
          nonce: nonce,
          merchantPubkey: merchantHex,
          amountMsat: 1000);
      expect(r.voucher, isNull);
      expect(r.fresh, isTrue);
    });

    test('un voucher con otro nonce se descarta', () async {
      final s = service(200, {
        ...payload(),
        'status': 'success',
        'voucher': voucherEvent(withNonce: 'ZzZzZzZzZzZzZzZzZzZzZz'),
      });
      final r = await s.svc.redeem(
          discovery: discovery(),
          nonce: nonce,
          merchantPubkey: merchantHex,
          amountMsat: 1000);
      expect(r.voucher, isNull);
    });

    test('410 vencido llega con las palabras del servidor', () async {
      final s = service(410, {'error': 'El cupón está vencido.'});
      await expectLater(
        s.svc.redeem(
            discovery: discovery(),
            nonce: nonce,
            merchantPubkey: merchantHex,
            amountMsat: 0),
        throwsA(isA<CouponException>()
            .having((e) => e.message, 'message', 'El cupón está vencido.')),
      );
    });
  });

  group('la orden que se archiva con el canje', () {
    const cafeD = '22222222-2222-4222-8222-222222222222';

    test('lleva bruto y descuento por separado', () async {
      final e = await buildCouponOrder(
        coupon: CouponInfo(
          status: 'minted',
          couponId: 'c-1',
          name: 'Bienvenida',
          description: '',
          npub: merchantNpub,
          nonce: nonce,
          benefit: parseBenefit({'type': 'percent', 'percent': 10}).value!,
        ),
        lines: const [
          OrderItem(name: 'Café', unitPrice: 250, qty: 2, d: cafeD, currency: Currency.ars),
        ],
        discounts: const [DiscountEntry(Currency.ars, 50)],
        merchantPubkey: merchantHex,
        amountMsat: 225000,
      );

      String? tag(String n) =>
          e.tags.firstWhere((t) => t[0] == n, orElse: () => []).elementAtOrNull(1);
      expect(e.kind, 9734);
      expect(verifyEvent(e), isTrue);
      // Bruto 500, descuento 50: la resta da lo cobrado. Guardar solo el neto
      // no se distingue de una canasta más barata.
      expect(tag('total'), '500');
      expect(tag('discount'), '50');
      expect(tag('items_count'), '2');
      expect(e.tags.firstWhere((t) => t[0] == 'coupon'), ['coupon', 'c-1', 'percent', 'Bienvenida']);
      expect(e.tags.firstWhere((t) => t[0] == 'item'),
          ['item', cafeD, '2', '250', 'ARS']);
    });

    test('una línea sin d (Caja registradora) no se inventa un producto', () async {
      final e = await buildCouponOrder(
        coupon: CouponInfo(
          status: 'minted',
          couponId: 'c-1',
          name: 'X',
          description: '',
          npub: merchantNpub,
          nonce: nonce,
          benefit: parseBenefit({'type': 'percent', 'percent': 10}).value!,
        ),
        lines: const [OrderItem(name: 'Cobro', unitPrice: 5000, qty: 1, currency: Currency.sat)],
        discounts: const [DiscountEntry(Currency.sat, 500)],
        merchantPubkey: merchantHex,
        amountMsat: 4500000,
      );
      expect(e.tags.where((t) => t[0] == 'item'), isEmpty);
      expect(e.tags.firstWhere((t) => t[0] == 'total'), ['total', '5000', 'SAT']);
    });
  });

  test('npubToHex ida y vuelta contra un npub real', () {
    expect(npubToHex(merchantNpub), merchantHex);
    expect(npubToHex(otherNpub),
        '888304a3aaed697e0df127753403607ae494ae425d6b4607fcc0b5822c26d815');
    expect(npubToHex('npub1nosoyunnpub'), isNull);
    expect(npubToHex(merchantHex), isNull);
  });
}
