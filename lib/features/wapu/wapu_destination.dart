/// Pure helpers that turn scanned or typed text into a destination the Wapu
/// mini-app can sell sats to. The address rules mirror survivors
/// `parse_lightning_address`, so the POS rejects what the backend would reject.
library;

import 'package:bolt11_decoder/bolt11_decoder.dart';

enum DestinationKind { lightningAddress, invoice, lnurl, invalid }

/// The least life an invoice must have left for the backend to pay it. The
/// backend checks it when the order is created, and again when it is funded.
const kWapuInvoiceMinLife = Duration(minutes: 15);

final RegExp _scheme = RegExp(r'^lightning:(//)?');
final RegExp _localPart = RegExp(r'^[a-z0-9\-_.+]{1,64}$');
final RegExp _domain = RegExp(
  r'^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$',
);

/// Trim, lowercase and drop a leading `lightning:` or `lightning://` scheme.
String normalizeDestination(String raw) =>
    raw.trim().toLowerCase().replaceFirst(_scheme, '').trim();

/// True when [normalized] is an address the backend accepts: exactly one `@`,
/// a valid local part and a valid domain. Expects already-normalized text.
bool isWapuLightningAddress(String normalized) {
  final parts = normalized.split('@');
  return parts.length == 2 &&
      _localPart.hasMatch(parts[0]) &&
      _domain.hasMatch(parts[1]);
}

/// Tells a lightning address from a BOLT11 invoice (see [parseWapuInvoice]) or
/// an LNURL, which the backend does not take. The address goes first: bech32
/// never holds an `@`, so `lnurl@example.com` is still an address.
DestinationKind classifyDestination(String raw) {
  final text = normalizeDestination(raw);
  if (isWapuLightningAddress(text)) return DestinationKind.lightningAddress;
  if (text.startsWith('lnbc') || text.startsWith('lntb')) {
    return DestinationKind.invoice;
  }
  if (text.startsWith('lnurl')) return DestinationKind.lnurl;
  return DestinationKind.invalid;
}

/// An invoice the backend can pay: on mainnet, with an amount, and more than
/// [kWapuInvoiceMinLife] left. [text] is the normalized invoice, [sats] what it
/// asks for and [expiresAt] when it stops being payable.
class WapuInvoice {
  const WapuInvoice({
    required this.text,
    required this.sats,
    required this.expiresAt,
  });

  final String text;
  final int sats;
  final DateTime expiresAt;
}

/// Why the backend cannot pay an invoice. [message] is Spanish source text, a
/// key of the i18n map, as the message of an `LnurlException` is.
class WapuInvoiceException implements Exception {
  const WapuInvoiceException(this.message);

  final String message;
}

const _invalid = WapuInvoiceException('El invoice no es válido');

/// Reads [normalized] (see [normalizeDestination]) as the BOLT11 invoice it is
/// at [now], or throws a [WapuInvoiceException] saying why the backend would
/// refuse it. An invoice keeps ageing, so the screen reads it again when the
/// operator confirms.
WapuInvoice parseWapuInvoice(String normalized, DateTime now) {
  // Mainnet is `lnbc`. `lnbcrt` is regtest, `lntb` testnet and `lntbs` signet.
  if (!normalized.startsWith('lnbc') || normalized.startsWith('lnbcrt')) {
    throw const WapuInvoiceException(
        'El invoice no es de la red principal de Bitcoin');
  }
  final Bolt11PaymentRequest pr;
  final DateTime expiresAt;
  try {
    pr = Bolt11PaymentRequest(normalized);
    // The `x` field says how many seconds it lives, and BOLT11 an hour when
    // there is none.
    final life = pr.tags
            .where((t) => t.type == 'expiry')
            .map((t) => t.data as int)
            .firstOrNull ??
        3600;
    expiresAt = DateTime.fromMillisecondsSinceEpoch(
        (pr.timestamp.toInt() + life) * 1000,
        isUtc: true);
  } catch (_) {
    // The decoder fails in another way for each way a text can be broken (the
    // checksum, a cut text, an amount nobody can read): none is worth telling
    // apart.
    throw _invalid;
  }
  final sats = pr.amount.shift(8); // the amount is in BTC
  if (sats.signum == 0) {
    throw const WapuInvoiceException(
        'El invoice no tiene monto. Pedile al cliente uno con monto.');
  }
  final whole = sats.toBigInt();
  // Not a whole number of sats, or one that an int cannot hold: not an amount.
  if (!sats.isInteger || whole.isNegative || !whole.isValidInt) throw _invalid;
  if (expiresAt.difference(now) <= kWapuInvoiceMinLife) {
    throw const WapuInvoiceException(
        'El invoice vence en menos de 15 minutos. Pedile al cliente uno nuevo.');
  }
  return WapuInvoice(
      text: normalized, sats: whole.toInt(), expiresAt: expiresAt);
}
