import 'package:flutter/foundation.dart';

import '../config/currencies.dart';
import '../config/formatter.dart';
import '../order/current_order.dart';

/// Coupons, the pure half: what a benefit takes off a basket. No I/O, no clock,
/// no singletons — the rate conversion arrives as a function so this is
/// testable without a network or a seeded PricingService.
///
/// Ported from lacrypta/merchant `src/lib/domain/coupon.ts`, which the merchant
/// panel and its storefront both price through. A discount must not mean one
/// thing at the till and another in the merchant's database, so the rules below
/// are kept deliberately close to that source.

/// The five shapes a coupon can take.
enum BenefitType { percent, fixed, multibuy, buyXgetY, freeItems }

/// A ceiling on what a coupon may take off, whatever its terms work out to.
///
/// "20% off, up to ARS 5.000" is what makes a percentage safe to hand out at
/// all: without it one unusually large basket eats the whole promo budget.
@immutable
class DiscountCap {
  final num amount;
  final Currency currency;
  const DiscountCap(this.amount, this.currency);
}

/// Units given away, by product `d`.
@immutable
class FreeUnits {
  final String d;
  final int qty;
  const FreeUnits(this.d, this.qty);
}

/// What a coupon takes off the bill.
///
/// One class with a [type] discriminator rather than a Dart sealed hierarchy:
/// the wire format is a single JSON object and every consumer switches on
/// `type` anyway. The fields not belonging to a type are null, and
/// [parseBenefit] is the only thing allowed to build one.
@immutable
class Benefit {
  final BenefitType type;

  /// `percent` only.
  final num? percent;

  /// `fixed` only.
  final num? amount;
  final Currency? currency;

  /// `multibuy` only. 2x1 is buy 2 pay 1.
  final int? buyQty;
  final int? payQty;

  /// `buyXgetY` only. Both equal is legal and is a 2x1.
  final String? buyProductD;
  final String? giftProductD;

  /// `freeItems` only. Never empty.
  final List<FreeUnits> items;

  /// Which products the discount applies to.
  ///
  /// **Absent means everything.** That default is the important half: a
  /// merchant who says "10% off" means the shop, and making them tick every
  /// product to say so would be a worse coupon system. An empty list is
  /// normalised to absent — whoever cleared the picker meant "all", not "none".
  final List<String>? productDs;

  final DiscountCap? cap;

  const Benefit({
    required this.type,
    this.percent,
    this.amount,
    this.currency,
    this.buyQty,
    this.payQty,
    this.buyProductD,
    this.giftProductD,
    this.items = const [],
    this.productDs,
    this.cap,
  });
}

const int maxMultibuyQty = 100;
const int maxFreeQty = 100;
const int maxCouponProducts = 50;

/// A discount MAY drive the bill to zero.
///
/// A zero-sat invoice is not payable — wallets reject it and LNURL declares a
/// `minSendable` of at least one sat — which is why a zero total produces no
/// invoice at all and the redemption itself becomes the record of the order.
const int minChargeSats = 0;

final RegExp _uuid =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        caseSensitive: false);
final RegExp _nonce = RegExp(r'^[A-Za-z0-9_-]{22}$');

/// Product references are the `d` tags the catalog generates — always UUIDs.
bool isProductD(Object? v) => v is String && _uuid.hasMatch(v);

/// The nonce is the coupon's whole credential. Checked before spending a
/// request on it.
bool isValidNonce(Object? v) => v is String && _nonce.hasMatch(v);

@immutable
class ParsedBenefit {
  final Benefit? value;
  final String? reason;
  const ParsedBenefit.ok(this.value) : reason = null;
  const ParsedBenefit.bad(this.reason) : value = null;
  bool get isOk => value != null;
}

int? _positiveInt(Object? v, int max) {
  if (v is! num || v != v.roundToDouble() || v <= 0 || v > max) return null;
  return v.toInt();
}

/// Absent, or a de-duplicated list of UUIDs. An empty list means "everything".
///
/// A malformed scope FAILS rather than falling back to absent. The fallback
/// would be the dangerous direction: "50% off this one mug" whose product list
/// we could not read would silently become 50% off the whole shop.
List<String>? _parseScope(Object? raw, {required void Function(String) fail}) {
  if (raw == null) return null;
  // Rows written before the scope became a list carry a singular `productD`.
  final list = raw is List ? raw : [raw];
  if (list.length > maxCouponProducts) {
    fail('no más de $maxCouponProducts productos');
    return null;
  }
  final out = <String>[];
  for (final v in list) {
    if (!isProductD(v)) {
      fail('hay un producto que no es válido');
      return null;
    }
    if (!out.contains(v)) out.add(v as String);
  }
  return out.isEmpty ? null : out;
}

DiscountCap? _parseCap(Object? raw, {required void Function(String) fail}) {
  if (raw == null) return null;
  if (raw is! Map) {
    fail('el tope es inválido');
    return null;
  }
  final amount = raw['amount'];
  final currency = CurrencyX.tryFromCode('${raw['currency']}');
  if (amount is! num || currency == null) {
    fail('el tope es inválido');
    return null;
  }
  // Zero is REJECTED rather than treated as absent: a ceiling of zero would be
  // a coupon that discounts nothing.
  if (amount <= 0) {
    fail('el tope tiene que ser mayor a 0');
    return null;
  }
  if (currency == Currency.sat && amount != amount.roundToDouble()) {
    fail('el tope en sats tiene que ser entero');
    return null;
  }
  return DiscountCap(amount, currency);
}

/// Parse a `Benefit` off the wire. Returns a reason rather than throwing, so a
/// broken coupon can be shown as broken instead of vanishing.
ParsedBenefit parseBenefit(Object? raw) {
  if (raw is! Map) return const ParsedBenefit.bad('el beneficio es inválido');

  String? why;
  final cap = _parseCap(raw['cap'], fail: (r) => why = r);
  if (why != null) return ParsedBenefit.bad(why);

  final scope = _parseScope(raw['productDs'] ?? raw['productD'], fail: (r) => why = r);
  if (why != null) return ParsedBenefit.bad(why);

  switch ('${raw['type']}') {
    case 'percent':
      final p = _positiveInt(raw['percent'], 100);
      if (p == null) {
        return const ParsedBenefit.bad(
            'el porcentaje tiene que ser un entero de 1 a 100');
      }
      return ParsedBenefit.ok(Benefit(
        type: BenefitType.percent,
        percent: p,
        productDs: scope,
        cap: cap,
      ));

    case 'fixed':
      final a = raw['amount'];
      final c = CurrencyX.tryFromCode('${raw['currency']}');
      if (a is! num || a <= 0 || c == null) {
        return const ParsedBenefit.bad('el monto es inválido');
      }
      if (c == Currency.sat && a != a.roundToDouble()) {
        return const ParsedBenefit.bad('el monto en sats tiene que ser entero');
      }
      return ParsedBenefit.ok(Benefit(
        type: BenefitType.fixed,
        amount: a,
        currency: c,
        productDs: scope,
        cap: cap,
      ));

    case 'multibuy':
      final buy = _positiveInt(raw['buyQty'], maxMultibuyQty);
      final pay = _positiveInt(raw['payQty'], maxMultibuyQty);
      if (buy == null || pay == null || pay >= buy) {
        return const ParsedBenefit.bad('la promo tiene que dar algo gratis');
      }
      return ParsedBenefit.ok(Benefit(
        type: BenefitType.multibuy,
        buyQty: buy,
        payQty: pay,
        productDs: scope,
        cap: cap,
      ));

    case 'buyXgetY':
      final b = raw['buyProductD'];
      final g = raw['giftProductD'];
      if (!isProductD(b) || !isProductD(g)) {
        return const ParsedBenefit.bad('elegí los dos productos');
      }
      return ParsedBenefit.ok(Benefit(
        type: BenefitType.buyXgetY,
        buyProductD: b as String,
        giftProductD: g as String,
        cap: cap,
      ));

    case 'freeItems':
      final raws = raw['items'];
      if (raws is! List || raws.isEmpty) {
        return const ParsedBenefit.bad('elegí al menos un producto');
      }
      if (raws.length > maxCouponProducts) {
        return const ParsedBenefit.bad('no más de $maxCouponProducts productos');
      }
      final items = <FreeUnits>[];
      for (final it in raws) {
        if (it is! Map) return const ParsedBenefit.bad('el producto es inválido');
        final d = it['d'];
        final qty = _positiveInt(it['qty'], maxFreeQty);
        if (!isProductD(d) || qty == null) {
          return const ParsedBenefit.bad('el producto es inválido');
        }
        // A repeated product could mean 2 or 5; guessing is worse than asking
        // for it once.
        if (items.any((f) => f.d == d)) {
          return const ParsedBenefit.bad('hay un producto repetido');
        }
        items.add(FreeUnits(d as String, qty));
      }
      return ParsedBenefit.ok(
          Benefit(type: BenefitType.freeItems, items: items, cap: cap));

    default:
      return const ParsedBenefit.bad('el tipo de cupón es desconocido');
  }
}

// ────────────────────────────────────────────────────────────── pricing

@immutable
class DiscountEntry {
  final Currency currency;
  final num amount;
  const DiscountEntry(this.currency, this.amount);
}

/// Why a coupon is not discounting anything right now.
///
/// Carrying the reason is the point: "el cupón no aplica" reads as a broken
/// coupon, while "te falta agregar 2 × Café" is something the cashier can act
/// on.
@immutable
class CouponUnmet {
  final String message;

  /// True when ANY ONE of the named products unlocks the coupon, false when all
  /// of them are required. A percentage scoped to five products needs one of
  /// the five; a buy-X-get-Y needs both sides.
  final bool anyOf;
  const CouponUnmet(this.message, {this.anyOf = true});
}

@immutable
class CouponQuote {
  /// Whole sats taken off, already clamped to what the goods are worth.
  final int discountSats;

  /// Per-currency breakdown, for the "Cupón — ARS 500" row.
  final List<DiscountEntry> entries;

  /// Units given away, for a "1 gratis" badge.
  final List<FreeUnits> freeUnits;

  /// Non-null means nothing was discounted, and why. **Do not consume the
  /// nonce when this is set.**
  final CouponUnmet? unmet;

  const CouponQuote({
    this.discountSats = 0,
    this.entries = const [],
    this.freeUnits = const [],
    this.unmet,
  });

  bool get applies => unmet == null && discountSats > 0;
}

List<DiscountEntry> _subtotals(Iterable<OrderItem> lines) {
  final out = <Currency, num>{};
  for (final l in lines) {
    out.update(l.priceCurrency, (v) => v + l.unitPrice * l.qty,
        ifAbsent: () => l.unitPrice * l.qty);
  }
  return [for (final e in out.entries) DiscountEntry(e.key, e.value)];
}

num _roundMoney(num amount, Currency c) =>
    c == Currency.sat ? amount.round() : num.parse(amount.toStringAsFixed(2));

/// The lines a scoped benefit may touch. No scope means the whole basket.
Iterable<OrderItem> _scoped(Iterable<OrderItem> lines, List<String>? scope) =>
    scope == null ? lines : lines.where((l) => scope.contains(l.d));

/// Units the coupon gives away, capped at what is actually in the basket.
List<FreeUnits> freeUnitsFor(List<OrderItem> lines, Benefit b) {
  switch (b.type) {
    case BenefitType.multibuy:
      return [
        for (final l in _scoped(lines, b.productDs))
          FreeUnits(l.d ?? '', (l.qty ~/ b.buyQty!) * (b.buyQty! - b.payQty!)),
      ].where((f) => f.qty > 0).toList();

    case BenefitType.freeItems:
      // A coupon for three coffees against a basket holding one gives one; it
      // never discounts units that are not there.
      return [
        for (final i in b.items)
          FreeUnits(
              i.d,
              [
                i.qty,
                lines.where((l) => l.d == i.d).fold<int>(0, (n, l) => n + l.qty),
              ].reduce((a, c) => a < c ? a : c)),
      ].where((f) => f.qty > 0).toList();

    case BenefitType.buyXgetY:
      final buy = lines.where((l) => l.d == b.buyProductD);
      final gift = lines.where((l) => l.d == b.giftProductD);
      if (buy.isEmpty || gift.isEmpty) return const [];
      // Same product on both sides is a 2x1: two are needed before one can be
      // free, otherwise the single unit bought IS the gift.
      final needed = b.buyProductD == b.giftProductD ? 2 : 1;
      if (gift.first.qty < needed) return const [];
      return [FreeUnits(gift.first.d ?? '', 1)];

    case BenefitType.percent:
    case BenefitType.fixed:
      return const [];
  }
}

List<DiscountEntry> _entriesFromTerms(List<OrderItem> lines, Benefit b) {
  switch (b.type) {
    case BenefitType.percent:
      return _subtotals(_scoped(lines, b.productDs))
          .map((s) => DiscountEntry(
              s.currency, _roundMoney(s.amount * b.percent! / 100, s.currency)))
          .where((s) => s.amount > 0)
          .toList();

    case BenefitType.fixed:
      if (b.productDs == null) return [DiscountEntry(b.currency!, b.amount!)];
      // Capped at what the named products are actually worth: "ARS 500 off
      // coffee" against a basket with ARS 200 of coffee takes off 200, not 500,
      // or a scoped coupon would quietly discount the rest of the cart.
      final eligible = _subtotals(_scoped(lines, b.productDs))
          .where((s) => s.currency == b.currency);
      final have = eligible.isEmpty ? 0 : eligible.first.amount;
      final amount = b.amount! < have ? b.amount! : have;
      return amount > 0 ? [DiscountEntry(b.currency!, amount)] : const [];

    case BenefitType.multibuy:
    case BenefitType.buyXgetY:
    case BenefitType.freeItems:
      final out = <Currency, num>{};
      for (final f in freeUnitsFor(lines, b)) {
        final match = lines.where((l) => l.d == f.d);
        if (match.isEmpty) continue;
        final line = match.first;
        out.update(line.priceCurrency, (v) => v + line.unitPrice * f.qty,
            ifAbsent: () => line.unitPrice * f.qty);
      }
      return [
        for (final e in out.entries)
          DiscountEntry(e.key, _roundMoney(e.value, e.key)),
      ].where((s) => s.amount > 0).toList();
  }
}

/// Hold a discount to its ceiling.
///
/// The cap clamps the entry in ITS OWN currency and leaves the rest alone —
/// converting would need a rate table this layer deliberately does not take,
/// and guessing at a number is worse than applying the ceiling where it was
/// authored.
List<DiscountEntry> discountEntries(List<OrderItem> lines, Benefit b) {
  final entries = _entriesFromTerms(lines, b);
  final cap = b.cap;
  if (cap == null) return entries;
  return [
    for (final e in entries)
      e.currency == cap.currency
          ? DiscountEntry(e.currency, e.amount < cap.amount ? e.amount : cap.amount)
          : e,
  ];
}

/// What the basket is still missing for a product-conditioned coupon to apply.
CouponUnmet? _missing(List<OrderItem> lines, Benefit b) {
  int have(String d) =>
      lines.where((l) => l.d == d).fold<int>(0, (n, l) => n + l.qty);

  switch (b.type) {
    case BenefitType.percent:
    case BenefitType.fixed:
      // Only reachable with a scope: an unscoped percentage always discounts a
      // non-empty basket.
      if (b.productDs == null) return null;
      return const CouponUnmet('El cupón aplica a productos que no están en la orden');

    case BenefitType.multibuy:
      return CouponUnmet('Faltan unidades para la promo ${b.buyQty}x${b.payQty}');

    case BenefitType.freeItems:
      final short = b.items.where((i) => have(i.d) < i.qty).length;
      return CouponUnmet(
          short == b.items.length
              ? 'Agregá alguno de los productos del cupón'
              : 'Faltan unidades de los productos del cupón');

    case BenefitType.buyXgetY:
      // Both sides are required, so "any one of these" would be a lie.
      return const CouponUnmet('Faltan los productos de la promo', anyOf: false);
  }
}

/// Price a basket against a coupon.
///
/// [goodsSats] is what the GOODS are worth in sats — the charge minus any tip.
/// The discount is clamped to it, so a tip is never discounted and the charge
/// can reach zero but never goes negative.
///
/// [toSats] converts an amount in a currency to whole sats, or null when the
/// rate is missing. A discount that cannot be converted is NOT guessed at:
/// charging full price would be wrong and charging an invented number worse.
CouponQuote quoteCoupon({
  required Benefit benefit,
  required int goodsSats,
  required List<OrderItem> lines,
  required int? Function(num amount, Currency currency) toSats,
}) {
  final entries = discountEntries(lines, benefit);
  if (entries.isEmpty) {
    return CouponQuote(
      unmet: _missing(lines, benefit) ??
          const CouponUnmet('El cupón no aplica a esta orden'),
    );
  }

  var discount = 0;
  for (final e in entries) {
    final sats = toSats(e.amount, e.currency);
    if (sats == null) {
      return CouponQuote(
        unmet: CouponUnmet('Todavía no tenemos la cotización de ${e.currency.code}'),
      );
    }
    discount += sats;
  }

  final spendable = goodsSats - minChargeSats;
  final capped = discount < spendable ? discount : spendable;
  return CouponQuote(
    discountSats: capped < 0 ? 0 : capped,
    entries: entries,
    freeUnits: freeUnitsFor(lines, benefit),
  );
}

/// One line describing what the coupon does, for the sheet and the ticket.
String describeBenefit(Benefit b, {String Function(String d)? titleOf}) {
  String name(String d) => titleOf?.call(d) ?? 'un producto';
  // Through the app's own formatter: a ticket that says "ARS 5000.0" is a
  // ticket nobody wrote on purpose.
  String money(num a, Currency c) => c == Currency.sat
      ? '${formatToPreference(c, a)} sat'
      : '${c.code} ${formatToPreference(c, a)}';
  String scope(List<String>? ds) => ds == null
      ? ''
      : ds.length == 1
          ? ' en ${name(ds.first)}'
          : ' en ${ds.length} productos';

  final terms = switch (b.type) {
    BenefitType.percent => '${b.percent}% de descuento${scope(b.productDs)}',
    BenefitType.fixed =>
      '${money(b.amount!, b.currency!)} de descuento${scope(b.productDs)}',
    BenefitType.multibuy => b.productDs == null
        ? '${b.buyQty}x${b.payQty} en cualquier producto'
        : '${b.buyQty}x${b.payQty}${scope(b.productDs)}',
    BenefitType.buyXgetY =>
      'Comprá ${name(b.buyProductD!)} y llevate ${name(b.giftProductD!)} gratis',
    BenefitType.freeItems => b.items.length == 1
        ? '${b.items.first.qty > 1 ? '${b.items.first.qty} × ' : ''}${name(b.items.first.d)} gratis'
        : '${b.items.fold<int>(0, (n, i) => n + i.qty)} productos gratis',
  };
  // The ceiling belongs in the same sentence: someone who reads "20% de
  // descuento" and is charged as if it were less has been told half the deal.
  return b.cap == null
      ? terms
      : '$terms (hasta ${money(b.cap!.amount, b.cap!.currency)})';
}
