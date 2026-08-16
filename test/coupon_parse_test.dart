import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/data/nostr/coupon_events.dart';
import 'package:lawallet_pos/data/nostr/event.dart';
import 'package:lawallet_pos/data/nostr/signer.dart';
import 'package:lawallet_pos/domain/config/currencies.dart';
import 'package:lawallet_pos/domain/coupon/coupon.dart';

const cafeD = '22222222-2222-4222-8222-222222222222';
const teD = '44444444-4444-4444-8444-444444444444';

NostrEvent announcement(String content, List<List<String>> tags) => NostrEvent(
      pubkey: '2ad91f1dca2dcd5fc89e7208d1e5059f0bac0870d63fc3bac21c7a9388fa18fd',
      createdAt: 1750000000,
      kind: kindAppData,
      tags: tags,
      content: content,
    );

void main() {
  group('el anuncio del servicio (kind 30078)', () {
    test('el v2 real de agustin@lacrypta.ar', () {
      final d = parseCouponDiscovery(announcement(
        '{"v":2,"mintUrl":"https://merchant.lacrypta.ar/api/coupons/mint",'
        '"claimUrl":"https://merchant.lacrypta.ar/api/coupons/claim"}',
        [
          ['d', couponDiscoveryD],
          ['p', '3ad4f9d26a47b0e39de5d1e327b0cefcb56141ad00325a020e5fe06d3877393e'],
          ['client', 'merchant-manager'],
        ],
      ));
      expect(d, isNotNull);
      expect(d!.managerPubkey,
          '3ad4f9d26a47b0e39de5d1e327b0cefcb56141ad00325a020e5fe06d3877393e');
      expect(d.claimUrl, 'https://merchant.lacrypta.ar/api/coupons/claim');
    });

    test('el v1 real de merch@lacrypta.ar se descarta entero', () {
      // Trae managerPubkey adentro del content y ningún tag p. Leerlo "casi
      // bien" apuntaría una caja a un endpoint cuyo significado adivinamos.
      expect(
        parseCouponDiscovery(announcement(
          '{"v":1,"managerPubkey":"fa231d94d47d986e5e1e6768f7ca30406e98c363cdfaba7ef2a59b17f1019f06",'
          '"mintUrl":"http://localhost:4321/api/coupons/mint",'
          '"claimUrl":"http://localhost:4321/api/coupons/claim"}',
          [
            ['d', couponDiscoveryD],
            ['client', 'merchant-manager'],
          ],
        )),
        isNull,
      );
    });

    test('sin tag p no hay a quién verificarle la firma', () {
      expect(
        parseCouponDiscovery(announcement(
          '{"v":2,"mintUrl":"https://m.ar/m","claimUrl":"https://m.ar/c"}',
          [
            ['d', couponDiscoveryD]
          ],
        )),
        isNull,
      );
    });

    test('http remoto se rechaza; localhost es la excepción de desarrollo', () {
      List<List<String>> tags = [
        ['d', couponDiscoveryD],
        ['p', '3ad4f9d26a47b0e39de5d1e327b0cefcb56141ad00325a020e5fe06d3877393e'],
      ];
      expect(
        parseCouponDiscovery(announcement(
            '{"v":2,"mintUrl":"http://m.ar/m","claimUrl":"http://m.ar/c"}', tags)),
        isNull,
      );
      expect(
        parseCouponDiscovery(announcement(
            '{"v":2,"mintUrl":"http://localhost:4321/m",'
            '"claimUrl":"http://localhost:4321/c"}',
            tags)),
        isNotNull,
      );
    });

    test('otro d en kind 30078 no es nuestro', () {
      expect(
        parseCouponDiscovery(announcement(
          '{"v":2,"mintUrl":"https://m.ar/m","claimUrl":"https://m.ar/c"}',
          [
            ['d', 'otra.app/config'],
            ['p', '3ad4f9d26a47b0e39de5d1e327b0cefcb56141ad00325a020e5fe06d3877393e'],
          ],
        )),
        isNull,
      );
    });
  });

  group('parseBenefit', () {
    test('un alcance ilegible NO se degrada a "todo el catálogo"', () {
      // Es la dirección peligrosa: un 50% sobre una taza cuya lista de
      // productos no pudimos leer sería un 50% sobre el local entero.
      final p = parseBenefit({
        'type': 'percent',
        'percent': 50,
        'productDs': ['no-es-un-uuid'],
      });
      expect(p.isOk, isFalse);
      expect(p.reason, isNotNull);
    });

    test('acepta el productD singular de las filas viejas', () {
      final p = parseBenefit({'type': 'percent', 'percent': 10, 'productD': cafeD});
      expect(p.value!.productDs, [cafeD]);
    });

    test('una lista vacía significa "todo", no "nada"', () {
      expect(
        parseBenefit({'type': 'percent', 'percent': 10, 'productDs': []}).value!.productDs,
        isNull,
      );
    });

    test('el porcentaje tiene que ser entero de 1 a 100', () {
      for (final bad in [0, 101, 12.5, '10', null]) {
        expect(parseBenefit({'type': 'percent', 'percent': bad}).isOk, isFalse,
            reason: 'aceptó $bad');
      }
      expect(parseBenefit({'type': 'percent', 'percent': 100}).isOk, isTrue);
    });

    test('un tope de 0 se rechaza en vez de tratarse como ausente', () {
      // Un techo de cero es un cupón que no descuenta nada.
      expect(
        parseBenefit({
          'type': 'percent',
          'percent': 10,
          'cap': {'amount': 0, 'currency': 'ARS'},
        }).isOk,
        isFalse,
      );
    });

    test('un tope en sats con decimales no se puede cobrar', () {
      expect(
        parseBenefit({
          'type': 'percent',
          'percent': 10,
          'cap': {'amount': 10.5, 'currency': 'SAT'},
        }).isOk,
        isFalse,
      );
    });

    test('freeItems: ni lista vacía ni producto repetido', () {
      expect(parseBenefit({'type': 'freeItems', 'items': []}).isOk, isFalse);
      expect(
        parseBenefit({
          'type': 'freeItems',
          'items': [
            {'d': cafeD, 'qty': 1},
            {'d': cafeD, 'qty': 4},
          ],
        }).isOk,
        isFalse,
      );
      expect(
        parseBenefit({
          'type': 'freeItems',
          'items': [
            {'d': cafeD, 'qty': 1},
            {'d': teD, 'qty': 2},
          ],
        }).value!.items.length,
        2,
      );
    });

    test('multibuy tiene que regalar algo', () {
      expect(
        parseBenefit({'type': 'multibuy', 'buyQty': 2, 'payQty': 2}).isOk,
        isFalse,
      );
    });

    test('una moneda que la POS no cobra se rechaza, no se adivina', () {
      expect(
        parseBenefit({'type': 'fixed', 'amount': 10, 'currency': 'EUR'}).isOk,
        isFalse,
      );
    });

    test('un tipo desconocido no se cuela', () {
      expect(parseBenefit({'type': 'freeShipping'}).isOk, isFalse);
    });
  });

  group('el voucher (kind 20402)', () {
    // Clave de prueba, no la de nadie.
    const managerKey =
        '0000000000000000000000000000000000000000000000000000000000000001';
    final managerPubkey = derivePublicKey(managerKey);
    const nonce = 'AbCdEfGhIjKlMnOpQrStUv';
    const owner =
        '2ad91f1dca2dcd5fc89e7208d1e5059f0bac0870d63fc3bac21c7a9388fa18fd';

    Map<String, dynamic> signed({String? withNonce, String? key}) {
      final payload = jsonEncode({
        'v': 1,
        'nonce': withNonce ?? nonce,
        'owner': owner,
        'name': 'Bienvenida',
        'description': '10% en tu primera compra',
        'coupon': {'type': 'percent', 'percent': 10},
        'phase': 'claimed',
        'claimedAt': 1750000000,
      });
      return signEvent(
        NostrEvent(
          pubkey: '',
          createdAt: 1750000000,
          kind: kindCouponVoucher,
          tags: [
            ['nonce', withNonce ?? nonce],
            ['p', owner],
          ],
          content: payload,
        ),
        key ?? managerKey,
      ).toJson();
    }

    test('un voucher bien firmado por el manager anunciado se acepta', () {
      final v = verifyVoucher(signed(),
          managerPubkey: managerPubkey, nonce: nonce);
      expect(v, isNotNull);
      expect(v!.name, 'Bienvenida');
      expect(v.benefit.percent, 10);
      expect(v.owner, owner);
    });

    test('firmado por otra clave se rechaza', () {
      // Sin esto, cualquier servicio que sepa firmar acuña descuentos en esta caja.
      expect(
        verifyVoucher(
          signed(
              key:
                  '0000000000000000000000000000000000000000000000000000000000000002'),
          managerPubkey: managerPubkey,
          nonce: nonce,
        ),
        isNull,
      );
    });

    test('el nonce del content tiene que ser el que canjeamos', () {
      // Si no, la respuesta de un canje puede traer el voucher de otro más generoso.
      expect(
        verifyVoucher(signed(withNonce: 'ZzZzZzZzZzZzZzZzZzZzZz'),
            managerPubkey: managerPubkey, nonce: nonce),
        isNull,
      );
    });

    test('una firma rota se rechaza', () {
      final e = signed();
      e['sig'] = '0${(e['sig'] as String).substring(1)}';
      expect(
        verifyVoucher(e, managerPubkey: managerPubkey, nonce: nonce),
        isNull,
      );
    });

    test('otro kind no pasa por voucher', () {
      final e = signed();
      e['kind'] = 1;
      expect(
        verifyVoucher(e, managerPubkey: managerPubkey, nonce: nonce),
        isNull,
      );
    });

    test('parseVoucherContent descarta v != 1', () {
      expect(parseVoucherContent('{"v":2,"nonce":"$nonce"}'), isNull);
      expect(parseVoucherContent('no es json'), isNull);
    });
  });

  test('isValidNonce filtra antes de gastar un pedido', () {
    expect(isValidNonce('AbCdEfGhIjKlMnOpQrStUv'), isTrue);
    expect(isValidNonce('corto'), isFalse);
    expect(isValidNonce('AbCdEfGhIjKlMnOpQrSt+/'), isFalse);
    expect(isValidNonce(null), isFalse);
  });

  test('describeBenefit dice el tope en la misma frase que los términos', () {
    // Alguien que lee "20% de descuento" y le cobran como si fuera menos
    // recibió la mitad del trato.
    final b = parseBenefit({
      'type': 'percent',
      'percent': 20,
      'cap': {'amount': 5000, 'currency': 'ARS'},
    }).value!;
    expect(describeBenefit(b), contains('20%'));
    expect(describeBenefit(b), contains('5.000'));
  });

  test('describeBenefit nombra el producto cuando lo conoce', () {
    final b = parseBenefit({
      'type': 'freeItems',
      'items': [
        {'d': cafeD, 'qty': 2}
      ],
    }).value!;
    expect(describeBenefit(b, titleOf: (d) => d == cafeD ? 'Café' : '?'),
        '2 × Café gratis');
  });

  test('un cap en una moneda ajena no toca las demás', () {
    // Convertir necesitaría una tabla de cotizaciones que esta capa no toma:
    // aplicar el techo donde fue escrito es mejor que inventar un número.
    final b = parseBenefit({
      'type': 'percent',
      'percent': 50,
      'cap': {'amount': 1, 'currency': 'USD'},
    }).value!;
    expect(b.cap!.currency, Currency.usd);
  });
}
