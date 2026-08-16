import 'dart:convert';
import 'dart:math';

import 'package:convert/convert.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../domain/coupon/coupon.dart';
import '../../domain/order/current_order.dart';
import '../../domain/order/order_tags.dart';
import '../nostr/event.dart';
import '../nostr/identity.dart';
import '../nostr/signer.dart';
import 'bech32_lnurl.dart';
import 'lnurl_helpers.dart';

/// dio on web often hands back the JSON body as a String; normalize to a Map.
Map<String, dynamic>? _asMap(dynamic data) {
  if (data is Map) return data.cast<String, dynamic>();
  if (data is String && data.isNotEmpty) {
    try {
      final decoded = jsonDecode(data);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {}
  }
  return null;
}

class LnurlException implements Exception {
  final String message;
  LnurlException(this.message);
  @override
  String toString() => message;
}

/// LNURL-pay parameters (LUD-06/LUD-16 `payRequest`).
class LnurlPayParams {
  final String callback;
  final int minSendable; // millisats
  final int maxSendable; // millisats
  final String? nostrPubkey;
  final bool allowsNostr;
  const LnurlPayParams({
    required this.callback,
    required this.minSendable,
    required this.maxSendable,
    this.nostrPubkey,
    this.allowsNostr = false,
  });
}

/// A generated invoice plus its optional LUD-21 verify URL and, when the
/// provider supports NIP-57, the info needed to watch for the zap receipt.
class LnurlInvoice {
  final String pr; // bolt11
  final String? verify; // LUD-21 verify endpoint
  final String? zapPubkey; // provider nostrPubkey (author of the zap receipt)
  final List<String> zapRelays; // relays to watch for the receipt
  final String? zapOrderId; // `e` tag placed in the zap request
  const LnurlInvoice({
    required this.pr,
    this.verify,
    this.zapPubkey,
    this.zapRelays = const [],
    this.zapOrderId,
  });

  bool get zapEnabled => zapPubkey != null && zapRelays.isNotEmpty;
}

/// Resolves Lightning Addresses and requests real invoices from their callback.
class LnurlService {
  LnurlService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
            ));

  final Dio _dio;
  final Map<String, LnurlPayParams> _cache = {};

  /// LUD-16 resolve: `user@domain` → `.well-known/lnurlp` payRequest params.
  Future<LnurlPayParams> resolve(String address) async {
    final cached = _cache[address];
    if (cached != null) return cached;

    final Response res;
    try {
      res = await _dio.getUri(Uri.parse(lud16ToUrl(address)));
    } catch (e) {
      throw LnurlException('No se pudo resolver la dirección Lightning');
    }
    final data = _asMap(res.data);
    if (data == null || data['tag'] != 'payRequest' || data['callback'] == null) {
      throw LnurlException('La dirección no es una Lightning Address válida');
    }
    final params = LnurlPayParams(
      callback: data['callback'] as String,
      minSendable: (data['minSendable'] as num?)?.toInt() ?? 1000,
      maxSendable: (data['maxSendable'] as num?)?.toInt() ?? (1 << 62),
      nostrPubkey: data['nostrPubkey'] as String?,
      allowsNostr: data['allowsNostr'] == true,
    );
    _cache[address] = params;
    return params;
  }

  /// Validate that [address] is a usable merchant address: a resolvable LUD-16
  /// Lightning Address (a valid `payRequest`). Throws [LnurlException] with a
  /// user-facing message otherwise.
  ///
  /// Payment confirmation (LUD-21 `verify` / NIP-57 zap receipt) is *not*
  /// required here — it's detected and used at payment time when the provider
  /// supports it, and re-checkable manually otherwise. Requiring it up front
  /// wrongly rejected valid addresses (e.g. `user@lawallet.io`, whose lnurlp
  /// omits `allowsNostr` and whose callback may be momentarily unavailable).
  Future<void> validate(String address) async {
    await resolve(address); // throws if not a resolvable, valid payRequest
  }

  /// Request a real bolt11 invoice for [sats] from the address's callback.
  ///
  /// When the provider supports NIP-57 (allowsNostr + nostrPubkey), [relays]
  /// are given AND [recipientPubkey] is known, a signed kind-9734 zap request is
  /// attached to the callback so the payment can be confirmed by watching for
  /// the kind-9735 zap receipt.
  ///
  /// [recipientPubkey] is the MERCHANT's own hex pubkey, from NIP-05 — the
  /// party being paid. Without it no zap request is sent at all: NIP-57 wants
  /// exactly one `p`, and naming the wrong key is worse than not zapping, since
  /// settlement is still detected by the LUD-21 poll either way.
  Future<LnurlInvoice> requestInvoice(String address, int sats,
      {List<String> relays = const [],
      String? recipientPubkey,
      List<OrderItem> lines = const [],
      List<DiscountEntry> discounts = const [],
      String? couponId,
      String? couponType,
      String? couponName}) async {
    final params = await resolve(address);
    final msats = sats * 1000;
    if (msats < params.minSendable) {
      throw LnurlException('Monto mínimo: ${params.minSendable ~/ 1000} sats');
    }
    if (msats > params.maxSendable) {
      throw LnurlException('Monto máximo: ${params.maxSendable ~/ 1000} sats');
    }

    // NIP-57: attach a signed zap request when the provider advertises support
    // and we know who is being paid.
    final zapPubkey = params.nostrPubkey;
    final useZap = params.allowsNostr &&
        (zapPubkey?.isNotEmpty ?? false) &&
        (recipientPubkey?.isNotEmpty ?? false) &&
        relays.isNotEmpty;
    var query = 'amount=$msats';
    String? orderId;
    if (useZap) {
      orderId = _randomHex(32);
      final lnurl = encodeLnurl(lud16ToUrl(address));
      final zapReq = await buildZapRequest(
        recipientPubkey: recipientPubkey!,
        amountMsats: msats,
        relays: relays,
        lnurl: lnurl,
        orderId: orderId,
        lines: lines,
        discounts: discounts,
        couponId: couponId,
        couponType: couponType,
        couponName: couponName,
      );
      query += '&nostr=${Uri.encodeComponent(jsonEncode(zapReq.toJson()))}';
      if (lnurl != null) query += '&lnurl=$lnurl';
    }

    final sep = params.callback.contains('?') ? '&' : '?';
    final Response res;
    try {
      res = await _dio.getUri(Uri.parse('${params.callback}$sep$query'));
    } catch (e) {
      throw LnurlException('No se pudo generar la invoice');
    }
    final data = _asMap(res.data);
    if (data == null || data['pr'] == null) {
      throw LnurlException(
          data?['reason']?.toString() ??
              'El proveedor no devolvió una invoice');
    }
    return LnurlInvoice(
      pr: data['pr'] as String,
      verify: data['verify'] as String?,
      zapPubkey: useZap ? zapPubkey : null,
      zapRelays: useZap ? relays : const [],
      zapOrderId: orderId,
    );
  }

  /// Build + sign a NIP-57 kind-9734 zap request with the app's Nostr identity.
  ///
  /// [recipientPubkey] is the party being paid — the merchant, hex, resolved
  /// from their NIP-05. It is NOT the provider's `nostrPubkey`: that key signs
  /// the RECEIPT, and on a custodial wallet it is one key shared by every
  /// account on the service. Both `agustin@lacrypta.ar` and
  /// `barra@lacrypta.ar` advertise the same one, so putting it here made every
  /// sale from every merchant look like a zap to La Crypta itself — invisible
  /// in the merchant's own `#p` feed, and thrown out by the merchant panel,
  /// which drops any receipt whose `p` is not the merchant.
  /// What was sold rides along as tags, so the merchant's order list shows the
  /// basket and not just an amount. The receipt copies the request verbatim into
  /// its `description`, which is where the panel reads them back from.
  @visibleForTesting
  Future<NostrEvent> buildZapRequest({
    required String recipientPubkey,
    required int amountMsats,
    required List<String> relays,
    required String orderId,
    String? lnurl,
    List<OrderItem> lines = const [],
    List<DiscountEntry> discounts = const [],
    String? couponId,
    String? couponType,
    String? couponName,
  }) async {
    final base = <List<String>>[
      ['relays', ...relays],
      ['amount', amountMsats.toString()],
      if (lnurl != null) ['lnurl', lnurl],
      ['p', recipientPubkey],
      ['e', orderId],
    ];
    var detail = orderTags(
      lines: lines,
      discounts: discounts,
      couponId: couponId,
      couponType: couponType,
      couponName: couponName,
    );

    // This event is URL-ENCODED into the callback's query string, so a long
    // basket does not merely bloat the request — it can push the GET past what
    // the provider accepts and cost us the invoice entirely. The line detail is
    // the first thing to go; the totals and the coupon stay.
    if (jsonEncode([...base, ...detail]).length > _maxZapTagChars) {
      detail = withoutLineDetail(detail);
    }

    final priv = await nostrIdentity.privateKey();
    final unsigned = NostrEvent(
      pubkey: await nostrIdentity.publicKey(), // cached — no repeat derivation
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: 9734,
      content: '',
      tags: [...base, ...detail],
    );
    return signEvent(unsigned, priv);
  }

  /// Tag budget for a zap request, in JSON characters before URL-encoding.
  /// Encoding roughly doubles it, leaving the whole GET comfortably under 2 KB.
  static const _maxZapTagChars = 900;

  String _randomHex(int bytes) {
    final rng = Random.secure();
    return hex.encode(List<int>.generate(bytes, (_) => rng.nextInt(256)));
  }

  /// Pay [invoice] by pulling from an LNURL-withdraw / Boltcard URL read via NFC.
  /// The card NDEF holds `lnurlw://…?p=…&c=…` (SUN); resolve it, then hit the
  /// withdraw callback with `k1` + the invoice `pr` to complete the payment.
  Future<void> payWithCard(String cardUrl, String invoice) async {
    var url = cardUrl.trim();
    final low = url.toLowerCase();
    if (low.startsWith('lightning://')) {
      url = url.substring('lightning://'.length);
    } else if (low.startsWith('lightning:')) {
      url = url.substring('lightning:'.length);
    }
    if (url.toLowerCase().startsWith('lnurlw://')) {
      url = 'https://${url.substring('lnurlw://'.length)}';
    } else if (!url.toLowerCase().startsWith('http')) {
      throw LnurlException('Formato de tarjeta no soportado');
    }

    final Response wres;
    try {
      wres = await _dio.getUri(Uri.parse(url));
    } catch (e) {
      throw LnurlException('No se pudo leer la tarjeta');
    }
    final w = _asMap(wres.data);
    if (w == null ||
        w['tag'] != 'withdrawRequest' ||
        w['callback'] == null ||
        w['k1'] == null) {
      throw LnurlException(
          w?['reason']?.toString() ?? 'La tarjeta no es una LNURL-withdraw válida');
    }
    final callback = w['callback'] as String;
    final k1 = w['k1'] as String;
    final sep = callback.contains('?') ? '&' : '?';

    final Response cres;
    try {
      cres = await _dio.getUri(Uri.parse(
          '$callback${sep}k1=${Uri.encodeComponent(k1)}&pr=${Uri.encodeComponent(invoice)}'));
    } catch (e) {
      throw LnurlException('No se pudo completar el pago con la tarjeta');
    }
    final c = _asMap(cres.data);
    if (c != null && c['status'] == 'ERROR') {
      throw LnurlException(c['reason']?.toString() ?? 'Pago con tarjeta rechazado');
    }
    // status OK — the withdraw service pays the invoice; settlement is detected
    // by the payment screen's LUD-21 polling.
  }

  /// Poll a LUD-21 verify URL once; true when the invoice is settled.
  Future<bool> checkSettled(String verifyUrl) async {
    final sep = verifyUrl.contains('?') ? '&' : '?';
    final res = await _dio.getUri(
      Uri.parse('$verifyUrl${sep}t=${DateTime.now().millisecondsSinceEpoch}'),
    );
    final data = _asMap(res.data);
    return data != null && data['status'] == 'OK' && data['settled'] == true;
  }
}

final LnurlService lnurl = LnurlService();
