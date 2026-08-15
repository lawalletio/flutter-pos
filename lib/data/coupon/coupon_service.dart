import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../domain/config/currencies.dart';
import '../../domain/coupon/coupon.dart';
import '../../domain/order/current_order.dart';
import '../nostr/coupon_events.dart';
import '../nostr/event.dart';
import '../nostr/identity.dart';
import '../nostr/signer.dart';

/// The claim endpoint a merchant advertised in their coupon announcement.
///
/// No NIP-98 here: the nonce IS the credential. Whoever holds the QR is holding
/// the coupon, which is the whole point — the person redeeming at the counter is
/// a customer, not somebody with an npub and a signer.

class CouponException implements Exception {
  final String message;
  CouponException(this.message);
  @override
  String toString() => message;
}

/// dio sometimes hands the JSON body back as a String; normalize.
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

/// A coupon as its issuer describes it.
@immutable
class CouponInfo {
  /// `minted` (good), `claimed`, `expired` or `voided`.
  final String status;
  final String couponId;
  final String name;
  final String description;

  /// The owning merchant, bech32. Checked against who we are charging for.
  final String npub;
  final String nonce;
  final String? image;
  final Benefit benefit;
  final int? expiresAt;
  final int? claimedAt;

  const CouponInfo({
    required this.status,
    required this.couponId,
    required this.name,
    required this.description,
    required this.npub,
    required this.nonce,
    required this.benefit,
    this.image,
    this.expiresAt,
    this.claimedAt,
  });

  bool get isRedeemable => status == 'minted';

  /// Why this coupon cannot be used, in words for the cashier.
  String get statusReason => switch (status) {
        'claimed' => 'Este cupón ya fue usado',
        'expired' => 'Este cupón está vencido',
        'voided' => 'Este cupón fue anulado',
        _ => 'Este cupón no se puede usar',
      };
}

/// The outcome of consuming a nonce.
@immutable
class CouponRedemption {
  final CouponInfo info;

  /// The manager's signature over the coupon. Null when the response carried no
  /// voucher or it did not verify — the redemption still happened.
  final Voucher? voucher;

  /// False means the server had already claimed this nonce. Not an error: a POS
  /// that lost our response and retried has to be able to tell "I redeemed
  /// this" from "somebody else did", and [CouponInfo.claimedAt] is how.
  final bool fresh;

  const CouponRedemption(
      {required this.info, required this.voucher, required this.fresh});
}

class CouponService {
  CouponService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
            ));

  final Dio _dio;

  /// Every status is read, never thrown: this API answers 404/410 with a reason
  /// the cashier needs to see. Set per request rather than on the client, so an
  /// injected [Dio] cannot turn "ese cupón no existe" into a network error.
  static final _readAnyStatus = Options(validateStatus: (_) => true);

  /// Look up a nonce **without consuming it**.
  ///
  /// Always call this before the POST. It is what lets the screen show the
  /// discount, and what keeps a coupon from being burned on a basket it turns
  /// out not to apply to.
  Future<CouponInfo> check(
    String claimUrl,
    String nonce, {
    required String merchantPubkey,
  }) async {
    if (!isValidNonce(nonce)) throw CouponException('Ese QR no es un cupón');
    final sep = claimUrl.contains('?') ? '&' : '?';
    final Response res;
    try {
      res = await _dio.getUri(Uri.parse('$claimUrl${sep}nonce=$nonce'),
          options: _readAnyStatus);
    } catch (_) {
      throw CouponException('No pudimos consultar el cupón');
    }
    return _readCoupon(res, merchantPubkey: merchantPubkey);
  }

  /// Consume the nonce. **Once.** There is no un-claim.
  ///
  /// [amountMsat] is what the customer is actually being charged after the
  /// discount; `0` marks the order as reclaimed rather than paid, and is the
  /// only record a free order will ever have.
  Future<CouponRedemption> redeem({
    required CouponDiscovery discovery,
    required String nonce,
    required String merchantPubkey,
    required int amountMsat,
    NostrEvent? order,
  }) async {
    if (!isValidNonce(nonce)) throw CouponException('Ese QR no es un cupón');
    final Response res;
    try {
      res = await _dio.postUri(
        Uri.parse(discovery.claimUrl),
        data: {
          'nonce': nonce,
          'amountMsat': amountMsat,
          if (order != null) 'zapRequest': order.toJson(),
        },
        options: _readAnyStatus,
      );
    } catch (_) {
      throw CouponException('No pudimos canjear el cupón');
    }
    final info = _readCoupon(res, merchantPubkey: merchantPubkey);
    final body = _asMap(res.data)!;
    return CouponRedemption(
      info: info,
      voucher: verifyVoucher(body['voucher'],
          managerPubkey: discovery.managerPubkey, nonce: nonce),
      fresh: body['status'] == 'success',
    );
  }

  CouponInfo _readCoupon(Response res, {required String merchantPubkey}) {
    final data = _asMap(res.data);
    if (res.statusCode != 200 || data == null) {
      throw CouponException(
        data?['error']?.toString() ??
            (res.statusCode == 404
                ? 'Ese cupón no existe'
                : 'No pudimos consultar el cupón'),
      );
    }

    final benefit = parseBenefit(data['coupon']);
    final nonce = data['nonce'];
    if (!benefit.isOk || !isValidNonce(nonce)) {
      throw CouponException(benefit.reason ?? 'El cupón llegó incompleto');
    }

    // The coupon must belong to the merchant we are charging for. One
    // deployment serves many merchants and answers for any nonce it knows, so
    // without this a 50% off one shop is spendable at the shop next door.
    final owner = npubToHex('${data['npub']}');
    if (owner == null || owner != merchantPubkey.toLowerCase()) {
      throw CouponException('Ese cupón es de otro comercio');
    }

    return CouponInfo(
      // POST answers `success`/`claimed`; GET answers the mint's own status.
      status: switch (data['status']) {
        'success' || 'claimed' when res.requestOptions.method == 'POST' =>
          'minted',
        final String s => s,
        _ => 'unknown',
      },
      couponId: '${data['couponId']}',
      name: data['name'] is String ? data['name'] as String : '',
      description:
          data['description'] is String ? data['description'] as String : '',
      npub: '${data['npub']}',
      nonce: nonce as String,
      benefit: benefit.value!,
      image: data['image'] is String ? data['image'] as String : null,
      expiresAt: (data['expiresAt'] as num?)?.toInt(),
      claimedAt: (data['claimedAt'] as num?)?.toInt(),
    );
  }
}

/// The maximum the server will accept for the filed order, in JSON characters.
const int maxOrderChars = 8000;

/// The order this coupon paid for, as a signed kind-9734.
///
/// Filed with the redemption so the merchant can see what a coupon bought. For
/// a free order it is the ONLY record that will ever exist: no invoice, no zap
/// receipt, and the coupon service keeps no order book of its own.
///
/// The `total` tags are GROSS and the `discount` tags are what came off, so
/// gross − discount is what was charged. Carrying both beats carrying the net
/// alone, which cannot be told apart from a cheaper basket.
Future<NostrEvent> buildCouponOrder({
  required CouponInfo coupon,
  required List<OrderItem> lines,
  required List<DiscountEntry> discounts,
  required String merchantPubkey,
  required int amountMsat,
}) async {
  final gross = <Currency, num>{};
  for (final l in lines) {
    gross.update(l.priceCurrency, (v) => v + l.unitPrice * l.qty,
        ifAbsent: () => l.unitPrice * l.qty);
  }

  final tags = <List<String>>[
    ['p', merchantPubkey],
    ['amount', '$amountMsat'],
    [
      'coupon',
      coupon.couponId,
      coupon.benefit.type.name,
      coupon.name,
    ],
    for (final e in gross.entries) ['total', '${e.value}', e.key.code],
    for (final d in discounts) ['discount', '${d.amount}', d.currency.code],
    if (lines.isNotEmpty)
      ['items_count', '${lines.fold<int>(0, (n, l) => n + l.qty)}'],
    // Lines without a `d` are dropped, not faked: a paydesk charge has no
    // product behind it and an invented id would corrupt the merchant's
    // per-product reporting.
    for (final l in lines)
      if (l.d != null && l.d!.isNotEmpty)
        ['item', l.d!, '${l.qty}', '${l.unitPrice}', l.priceCurrency.code],
  ];

  var unsigned = NostrEvent(
    pubkey: await nostrIdentity.publicKey(),
    createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    kind: 9734,
    content: '',
    tags: tags,
  );
  // A long basket would be rejected wholesale. Shedding the per-line detail
  // keeps the coupon, the totals and the discount — the parts the merchant is
  // owed — rather than losing the entire record to its own length.
  if (jsonEncode(unsigned.toJson()).length > maxOrderChars) {
    unsigned = NostrEvent(
      pubkey: unsigned.pubkey,
      createdAt: unsigned.createdAt,
      kind: unsigned.kind,
      content: '',
      tags: tags.where((t) => t[0] != 'item').toList(),
    );
  }
  return signEvent(unsigned, await nostrIdentity.privateKey());
}

final CouponService coupons = CouponService();
