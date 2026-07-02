import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Current Bitcoin block height from mempool.space, cached in memory and
/// refreshed on a timer so it's instantly available when composing a ticket
/// (no network round-trip while printing). Mirrors the webapp's block source.
class BlockService {
  BlockService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;
  final ValueNotifier<int?> notifier = ValueNotifier<int?>(null);
  DateTime? _loadedAt;
  Future<void>? _inFlight;
  Timer? _timer;

  static const _endpoint = 'https://mempool.space/api/v1/blocks/tip/height';
  static const _ttl = Duration(seconds: 60);

  int? get height => notifier.value;

  /// Load if missing or stale (deduped across concurrent callers).
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
      final raw = res.data;
      final h = raw is int ? raw : int.tryParse(raw.toString().trim());
      if (h != null && h > 0) {
        notifier.value = h;
        _loadedAt = DateTime.now();
      }
    } catch (e) {
      debugPrint('BlockService: failed to load height: $e');
    }
  }

  /// Load now and keep refreshing every [period] so the value stays current.
  void startAutoRefresh([Duration period = const Duration(seconds: 60)]) {
    ensureLoaded();
    _timer?.cancel();
    _timer = Timer.periodic(period, (_) {
      _loadedAt = null; // force a refresh past the TTL
      ensureLoaded();
    });
  }
}

/// App-wide block-height singleton.
final BlockService blockHeight = BlockService();
