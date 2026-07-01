/// LNURL / Lightning-address string helpers. Faithful port of the pure helpers in
/// `src/lib/utils.ts` (bech32 LNURL decode is added in M2 once the `bech32`
/// package API is wired — see `normalizeLnurl`).
library;

enum TransferType { lud16, lnurl, invoice }

final RegExp _emailRe = RegExp(r'^([^@]+)@(.+)$');

bool validateEmail(String value) => _emailRe.hasMatch(value);

/// `detectTransferType` — classify a scanned/typed string.
TransferType? detectTransferType(String data) {
  final upper = data.toUpperCase();
  if (validateEmail(upper)) return TransferType.lud16;
  if (upper.startsWith('LNURL')) return TransferType.lnurl;
  if (upper.startsWith('LNBC')) return TransferType.invoice;
  return null;
}

/// `isValidLightningURL`.
bool isValidLightningUrl(String url) => RegExp(
      r'^lightning:\/\/[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$',
    ).hasMatch(url);

/// `removeLightningStandard` — strip a `lightning:` / `lightning://` prefix.
String removeLightningStandard(String str) {
  final low = str.toLowerCase();
  if (low.startsWith('lightning://')) return low.replaceFirst('lightning://', '');
  if (low.startsWith('lightning:')) return low.replaceFirst('lightning:', '');
  return low;
}

/// `extractEmailParts`.
({String? username, String? domain}) extractEmailParts(String email) {
  final m = _emailRe.firstMatch(email);
  if (m == null) return (username: null, domain: null);
  return (username: m.group(1), domain: m.group(2));
}

/// Resolve a Lightning Address (LUD-16) to its well-known LNURL-pay URL.
/// `user@domain` → `https://domain/.well-known/lnurlp/user`.
String lud16ToUrl(String address) {
  final parts = extractEmailParts(address.trim().toLowerCase());
  if (parts.username == null || parts.domain == null) {
    throw ArgumentError('Invalid Lightning Address: $address');
  }
  return 'https://${parts.domain}/.well-known/lnurlp/${parts.username}';
}

/// NIP-05 well-known lookup URL for a `name@domain`.
String nip05ToUrl(String address) {
  final parts = extractEmailParts(address.trim().toLowerCase());
  if (parts.username == null || parts.domain == null) {
    throw ArgumentError('Invalid NIP-05 address: $address');
  }
  return 'https://${parts.domain}/.well-known/nostr.json?name=${parts.username}';
}

bool isValidUrl(String s) => RegExp(
      r'[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()@:%_\+.~#?&//=]*)?',
    ).hasMatch(s);
