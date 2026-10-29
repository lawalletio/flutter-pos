/// Pure helpers that turn scanned or typed text into a destination the Wapu
/// mini-app can sell sats to. The address rules mirror survivors
/// `parse_lightning_address`, so the POS rejects what the backend would reject.
library;

enum DestinationKind { lightningAddress, invoice, lnurl, invalid }

final RegExp _scheme = RegExp(r'^lightning:');
final RegExp _localPart = RegExp(r'^[a-z0-9\-_.+]{1,64}$');
final RegExp _domain = RegExp(
  r'^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$',
);

/// Trim, lowercase and drop a leading `lightning:` scheme.
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

/// Tells a lightning address from a BOLT11 invoice or an LNURL, which the
/// backend does not take. The address goes first: bech32 never holds an `@`,
/// so `lnurl@example.com` is still an address.
DestinationKind classifyDestination(String raw) {
  final text = normalizeDestination(raw);
  if (isWapuLightningAddress(text)) return DestinationKind.lightningAddress;
  if (text.startsWith('lnbc') || text.startsWith('lntb')) {
    return DestinationKind.invoice;
  }
  if (text.startsWith('lnurl')) return DestinationKind.lnurl;
  return DestinationKind.invalid;
}
