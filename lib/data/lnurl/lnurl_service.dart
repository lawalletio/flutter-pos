import 'dart:convert';
import 'dart:math';

import 'package:convert/convert.dart';
import 'package:dio/dio.dart';

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

  /// Validate that [address] is a usable merchant address: LUD-16 resolvable AND
  /// supports payment confirmation via either NIP-57 zaps (allowsNostr +
  /// nostrPubkey) or LUD-21 (`verify`). Throws [LnurlException] with a
  /// user-facing message otherwise.
  Future<void> validate(String address) async {
    final params = await resolve(address); // throws if not a valid payRequest
    final supportsNostr =
        params.allowsNostr && (params.nostrPubkey?.isNotEmpty ?? false);
    if (supportsNostr) return; // NIP-57 available
    // Otherwise require LUD-21: request a minimal invoice and look for `verify`.
    final minSats =
        (params.minSendable ~/ 1000) < 1 ? 1 : params.minSendable ~/ 1000;
    LnurlInvoice inv;
    try {
      inv = await requestInvoice(address, minSats);
    } catch (_) {
      throw LnurlException(
          'El proveedor no soporta confirmación de pago (LUD-21 ni NIP-57)');
    }
    if (inv.verify == null || inv.verify!.isEmpty) {
      throw LnurlException(
          'El proveedor no soporta confirmación de pago (LUD-21 ni NIP-57)');
    }
  }

  /// Request a real bolt11 invoice for [sats] from the address's callback.
  ///
  /// When the provider supports NIP-57 (allowsNostr + nostrPubkey) and [relays]
  /// are given, a signed kind-9734 zap request is attached to the callback so
  /// the payment can be confirmed by watching for the kind-9735 zap receipt.
  Future<LnurlInvoice> requestInvoice(String address, int sats,
      {List<String> relays = const []}) async {
    final params = await resolve(address);
    final msats = sats * 1000;
    if (msats < params.minSendable) {
      throw LnurlException('Monto mínimo: ${params.minSendable ~/ 1000} sats');
    }
    if (msats > params.maxSendable) {
      throw LnurlException('Monto máximo: ${params.maxSendable ~/ 1000} sats');
    }

    // NIP-57: attach a signed zap request when the provider advertises support.
    final zapPubkey = params.nostrPubkey;
    final useZap = params.allowsNostr &&
        (zapPubkey?.isNotEmpty ?? false) &&
        relays.isNotEmpty;
    var query = 'amount=$msats';
    String? orderId;
    if (useZap) {
      orderId = _randomHex(32);
      final lnurl = encodeLnurl(lud16ToUrl(address));
      final zapReq = await _buildZapRequest(
        recipientPubkey: zapPubkey!,
        amountMsats: msats,
        relays: relays,
        lnurl: lnurl,
        orderId: orderId,
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
  Future<NostrEvent> _buildZapRequest({
    required String recipientPubkey,
    required int amountMsats,
    required List<String> relays,
    required String orderId,
    String? lnurl,
  }) async {
    final priv = await nostrIdentity.privateKey();
    final unsigned = NostrEvent(
      pubkey: derivePublicKey(priv),
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      kind: 9734,
      content: '',
      tags: [
        ['relays', ...relays],
        ['amount', amountMsats.toString()],
        if (lnurl != null) ['lnurl', lnurl],
        ['p', recipientPubkey],
        ['e', orderId],
      ],
    );
    return signEvent(unsigned, priv);
  }

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
