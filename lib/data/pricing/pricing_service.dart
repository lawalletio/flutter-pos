import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../domain/config/currencies.dart';

/// BTC exchange rates from yadio, expressed as *fiat per sat*.
@immutable
class Rates {
  final double arsPerSat;
  final double usdPerSat;
  const Rates(this.arsPerSat, this.usdPerSat);

  double perSat(Currency c) {
    switch (c) {
      case Currency.ars:
        return arsPerSat;
      case Currency.usd:
        return usdPerSat;
      case Currency.sat:
        return 1;
    }
  }
}

/// Real fiat↔sats conversion backed by `https://api.yadio.io/exrates/btc`.
///
/// yadio returns the price of 1 BTC in each fiat (`BTC.ARS`, `BTC.USD`); dividing
/// by 1e8 gives the fiat value of a single sat — the same math the webapp uses in
/// `useCurrencyConverter`.
class PricingService {
  PricingService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;
  final ValueNotifier<Rates?> notifier = ValueNotifier<Rates?>(null);
  DateTime? _loadedAt;
  Future<void>? _inFlight;

  static const _endpoint = 'https://api.yadio.io/exrates/btc';
  static const _ttl = Duration(seconds: 60);

  Rates? get rates => notifier.value;

  /// Seed rates directly (tests) so [ensureLoaded] treats them as fresh.
  @visibleForTesting
  void seedRates(Rates rates) {
    notifier.value = rates;
    _loadedAt = DateTime.now();
  }

  /// Load rates if missing or stale (deduped across concurrent callers).
  Future<void> ensureLoaded() {
    final fresh = _loadedAt != null &&
        DateTime.now().difference(_loadedAt!) < _ttl &&
        notifier.value != null;
    if (fresh) return Future.value();
    return _inFlight ??= _load().whenComplete(() => _inFlight = null);
  }

  Future<void> _load() async {
    try {
      final res = await _dio.get<dynamic>(_endpoint);
      // dio on web may return the body as a String; normalize to a Map.
      final data = res.data is String
          ? jsonDecode(res.data as String) as Map
          : res.data as Map;
      final btc = (data['BTC'] as Map).cast<String, dynamic>();
      final ars = (btc['ARS'] as num).toDouble() / 1e8;
      final usd = (btc['USD'] as num).toDouble() / 1e8;
      notifier.value = Rates(ars, usd);
      _loadedAt = DateTime.now();
    } catch (e) {
      debugPrint('PricingService: failed to load rates: $e');
      rethrow;
    }
  }

  /// Convert a fiat (or SAT) amount to whole sats. Returns null if rates aren't
  /// loaded yet for a fiat currency.
  int? fiatToSats(num amount, Currency currency) {
    if (currency == Currency.sat) return amount.round();
    final r = notifier.value;
    if (r == null) return null;
    final perSat = r.perSat(currency);
    if (perSat <= 0) return null;
    return (amount / perSat).round();
  }

  /// Convert sats to a fiat amount. Returns null if rates aren't loaded yet.
  double? satsToFiat(int sats, Currency currency) {
    if (currency == Currency.sat) return sats.toDouble();
    final r = notifier.value;
    if (r == null) return null;
    return sats * r.perSat(currency);
  }
}

/// App-wide pricing singleton.
final PricingService pricing = PricingService();
