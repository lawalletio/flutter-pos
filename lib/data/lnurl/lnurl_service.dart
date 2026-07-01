import 'dart:convert';

import 'package:dio/dio.dart';

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

/// A generated invoice plus its optional LUD-21 verify URL.
class LnurlInvoice {
  final String pr; // bolt11
  final String? verify; // LUD-21 verify endpoint
  const LnurlInvoice({required this.pr, this.verify});
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

  /// Request a real bolt11 invoice for [sats] from the address's callback.
  Future<LnurlInvoice> requestInvoice(String address, int sats) async {
    final params = await resolve(address);
    final msats = sats * 1000;
    if (msats < params.minSendable) {
      throw LnurlException('Monto mínimo: ${params.minSendable ~/ 1000} sats');
    }
    if (msats > params.maxSendable) {
      throw LnurlException('Monto máximo: ${params.maxSendable ~/ 1000} sats');
    }

    final sep = params.callback.contains('?') ? '&' : '?';
    final Response res;
    try {
      res = await _dio.getUri(Uri.parse('${params.callback}${sep}amount=$msats'));
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
    );
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
