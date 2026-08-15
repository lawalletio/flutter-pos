import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../domain/coupon/coupon.dart';
import 'event.dart';
import 'signer.dart';

/// The two nostr events the coupon flow reads.
///
/// Neither is ever published by this app: the announcement is written by the
/// merchant's own panel, and the voucher is signed by the coupon service and
/// handed back over HTTPS — it is deliberately never on a relay at all.

/// NIP-78 app data. Shared by every app, so the `d` below is the whole fence.
const int kindAppData = 30078;

/// Ephemeral (2xxxx), and that is on purpose: a voucher is a bearer credential.
const int kindCouponVoucher = 20402;

/// Our `d` tag on kind 30078.
const String couponDiscoveryD = 'lacrypta.merchant/coupons';

final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);

String? _tag(NostrEvent e, String name) {
  for (final t in e.tags) {
    if (t.length >= 2 && t[0] == name) return t[1];
  }
  return null;
}

/// Where a merchant's coupons are minted and claimed, and whose signature to
/// expect on the vouchers those endpoints return.
///
/// This is what lets a POS that has never spoken to the coupon service redeem
/// against it: the merchant authorised the service by signing this, and the
/// authorisation travels with the npub.
@immutable
class CouponDiscovery {
  /// Hex pubkey of the service that signs vouchers.
  final String managerPubkey;

  /// POST, NIP-98, authorised npubs only. This app never calls it — minting
  /// needs the merchant's key, which the POS does not hold.
  final String mintUrl;

  /// GET to check a nonce, POST to redeem it.
  final String claimUrl;

  const CouponDiscovery({
    required this.managerPubkey,
    required this.mintUrl,
    required this.claimUrl,
  });

  Map<String, dynamic> toJson() =>
      {'p': managerPubkey, 'mintUrl': mintUrl, 'claimUrl': claimUrl};

  static CouponDiscovery? fromJson(Object? j) {
    if (j is! Map) return null;
    final p = '${j['p']}';
    final mint = _endpoint(j['mintUrl']);
    final claim = _endpoint(j['claimUrl']);
    if (!_hex64.hasMatch(p) || mint == null || claim == null) return null;
    return CouponDiscovery(
        managerPubkey: p.toLowerCase(), mintUrl: mint, claimUrl: claim);
  }
}

/// https only, with the localhost exception the panel uses for `npm run dev`.
String? _endpoint(Object? raw) {
  if (raw is! String) return null;
  final value = raw.trim();
  if (value.isEmpty || value.length > 500) return null;
  final url = Uri.tryParse(value);
  if (url == null || !url.hasAuthority || url.userInfo.isNotEmpty) return null;
  final local = url.host == 'localhost' || url.host == '127.0.0.1';
  if (url.scheme != 'https' && !(local && url.scheme == 'http')) return null;
  return url.toString();
}

/// Read the announcement — the whole event, because half of it is a tag.
///
/// Two rules from the spec that are not optional:
///
/// **Any version other than 2 is discarded, never half-migrated.** A merchant
/// still on v1 simply has no coupons here; pointing a till at a URL whose
/// meaning we guessed is the worse outcome. (`merch@lacrypta.ar` is exactly
/// this case today.)
///
/// **Never fetch this by `#p`.** Kind 30078 is addressable: asking a relay for
/// "the announcement naming this manager" can return a superseded version while
/// the merchant's current one names somebody else. Fetch the newest by author +
/// `d`, then read the `p`.
CouponDiscovery? parseCouponDiscovery(NostrEvent e) {
  if (e.kind != kindAppData || _tag(e, 'd') != couponDiscoveryD) return null;
  Object? raw;
  try {
    raw = jsonDecode(e.content);
  } catch (_) {
    return null;
  }
  if (raw is! Map || raw['v'] != 2) return null;
  return CouponDiscovery.fromJson({
    'p': _tag(e, 'p'),
    'mintUrl': raw['mintUrl'],
    'claimUrl': raw['claimUrl'],
  });
}

/// A coupon signed by the manager key.
///
/// The claim response is plain JSON over HTTPS, which only proves it came from
/// whoever holds the certificate. The voucher proves it came from the service
/// the *merchant* named — which is the thing the cashier actually needs.
@immutable
class Voucher {
  final String nonce;

  /// The coupon owner's pubkey, hex. Must be the merchant being charged.
  final String owner;
  final String name;
  final String description;
  final Benefit benefit;

  /// `minted` or `claimed`.
  final String phase;
  final String? image;
  final int? claimedAt;
  final int? expiresAt;

  const Voucher({
    required this.nonce,
    required this.owner,
    required this.name,
    required this.description,
    required this.benefit,
    required this.phase,
    this.image,
    this.claimedAt,
    this.expiresAt,
  });
}

/// Read a voucher's content. Says nothing about who signed it — use
/// [verifyVoucher] for that.
Voucher? parseVoucherContent(String content) {
  Object? raw;
  try {
    raw = jsonDecode(content);
  } catch (_) {
    return null;
  }
  if (raw is! Map || raw['v'] != 1) return null;
  final nonce = raw['nonce'];
  final owner = '${raw['owner']}';
  final phase = raw['phase'];
  if (!isValidNonce(nonce) || !_hex64.hasMatch(owner)) return null;
  if (phase != 'minted' && phase != 'claimed') return null;
  final benefit = parseBenefit(raw['coupon']);
  if (!benefit.isOk) return null;
  return Voucher(
    nonce: nonce as String,
    owner: owner.toLowerCase(),
    name: raw['name'] is String ? raw['name'] as String : '',
    description: raw['description'] is String ? raw['description'] as String : '',
    benefit: benefit.value!,
    phase: phase as String,
    image: raw['image'] is String ? raw['image'] as String : null,
    claimedAt: raw['claimedAt'] is num ? (raw['claimedAt'] as num).toInt() : null,
    expiresAt: raw['expiresAt'] is num ? (raw['expiresAt'] as num).toInt() : null,
  );
}

/// The voucher, or null if it does not belong to this redemption.
///
/// All four checks matter, and each rules out a different way of being handed
/// somebody else's coupon:
///
/// - the kind, so a replayed event of another type cannot pass as a voucher;
/// - the author, against the manager the *merchant* named in their
///   announcement — otherwise any service that can sign could mint discounts on
///   this till;
/// - the signature, because without it the pubkey is just a claim;
/// - the nonce, so the response to one redemption cannot carry the voucher of
///   another, more generous one.
Voucher? verifyVoucher(
  Object? rawEvent, {
  required String managerPubkey,
  required String nonce,
}) {
  if (rawEvent is! Map) return null;
  final NostrEvent e;
  try {
    e = NostrEvent.fromJson(rawEvent.cast<String, dynamic>());
  } catch (_) {
    return null;
  }
  if (e.kind != kindCouponVoucher) return null;
  if (e.pubkey.toLowerCase() != managerPubkey.toLowerCase()) return null;
  if (!verifyEvent(e)) return null;
  final v = parseVoucherContent(e.content);
  return v != null && v.nonce == nonce ? v : null;
}

/// The merchant's current announcement, out of everything read for them.
///
/// Newest by `created_at` among their own kind-30078 events carrying our `d` —
/// which is the only correct way to read an addressable event. An older version
/// can name a manager the merchant has since stopped using.
CouponDiscovery? latestCouponDiscovery(
    Iterable<NostrEvent> events, String pubkey) {
  NostrEvent? newest;
  for (final e in events) {
    if (e.pubkey != pubkey) continue;
    if (e.kind != kindAppData || _tag(e, 'd') != couponDiscoveryD) continue;
    if (newest == null || e.createdAt > newest.createdAt) newest = e;
  }
  return newest == null ? null : parseCouponDiscovery(newest);
}
