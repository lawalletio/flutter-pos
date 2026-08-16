import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'current_order.dart';

/// A recorded POS order, persisted (shared_preferences) so the Orders screen
/// survives restarts — and **starts empty on a fresh install** (no seed data).
///
/// Pending orders keep the info needed to re-verify settlement later: the LUD-21
/// `verifyUrl` and the NIP-57 zap details (provider pubkey, relays, invoice).
@immutable
class OrderRecord {
  final String id;
  final int createdAt; // millis since epoch
  final int amountSats;
  final String summary;
  final bool isPaid;
  final String? verifyUrl; // LUD-21
  final String? invoice; // bolt11 (matched against the NIP-57 receipt)
  final String? zapPubkey; // NIP-57 provider nostrPubkey
  final List<String> zapRelays;
  final String? zapOrderId; // `e` tag placed in the zap request
  final List<OrderItem> items; // ticket line items (snapshot at checkout)

  /// The coupon applied, if any. [amountSats] is already NET of
  /// [discountSats] — the two together give the gross, which is what the
  /// reprinted ticket shows.
  final String? couponId;
  final String? couponName;
  final String? couponNonce;
  final int discountSats;

  const OrderRecord({
    required this.id,
    required this.createdAt,
    required this.amountSats,
    required this.summary,
    this.isPaid = false,
    this.verifyUrl,
    this.invoice,
    this.zapPubkey,
    this.zapRelays = const [],
    this.zapOrderId,
    this.items = const [],
    this.couponId,
    this.couponName,
    this.couponNonce,
    this.discountSats = 0,
  });

  DateTime get createdAtDate => DateTime.fromMillisecondsSinceEpoch(createdAt);

  bool get supportsLud21 => verifyUrl != null && verifyUrl!.isNotEmpty;
  bool get supportsNip57 =>
      zapPubkey != null &&
      zapPubkey!.isNotEmpty &&
      (invoice?.isNotEmpty ?? false) &&
      zapRelays.isNotEmpty;
  bool get canRecheck => supportsLud21 || supportsNip57;

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt,
        'amountSats': amountSats,
        'summary': summary,
        'isPaid': isPaid,
        'verifyUrl': verifyUrl,
        'invoice': invoice,
        'zapPubkey': zapPubkey,
        'zapRelays': zapRelays,
        'zapOrderId': zapOrderId,
        'items': items.map((it) => it.toJson()).toList(),
        if (couponId != null) 'couponId': couponId,
        if (couponName != null) 'couponName': couponName,
        if (couponNonce != null) 'couponNonce': couponNonce,
        if (discountSats > 0) 'discountSats': discountSats,
      };

  /// What the order would have cost without the coupon.
  int get grossSats => amountSats + discountSats;
  bool get hasCoupon => discountSats > 0 || couponName != null;

  factory OrderRecord.fromJson(Map<String, dynamic> j) => OrderRecord(
        id: j['id'] as String,
        createdAt: (j['createdAt'] as num).toInt(),
        amountSats: (j['amountSats'] as num).toInt(),
        summary: j['summary'] as String? ?? '',
        isPaid: j['isPaid'] == true,
        verifyUrl: j['verifyUrl'] as String?,
        invoice: j['invoice'] as String?,
        zapPubkey: j['zapPubkey'] as String?,
        zapRelays: (j['zapRelays'] as List?)?.map((e) => e.toString()).toList() ??
            const [],
        zapOrderId: j['zapOrderId'] as String?,
        items: (j['items'] as List?)
                ?.map((e) => OrderItem.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        couponId: j['couponId'] as String?,
        couponName: j['couponName'] as String?,
        couponNonce: j['couponNonce'] as String?,
        discountSats: (j['discountSats'] as num?)?.toInt() ?? 0,
      );
}

/// Session/persisted order history. Most-recent first.
class OrdersStore {
  static const _key = 'ordersCache';

  final ValueNotifier<List<OrderRecord>> notifier =
      ValueNotifier<List<OrderRecord>>([]);
  SharedPreferences? _prefs;

  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<void> load() async {
    final p = await _p;
    final raw = p.getStringList(_key) ?? const [];
    notifier.value = raw
        .map((s) {
          try {
            return OrderRecord.fromJson(jsonDecode(s) as Map<String, dynamic>);
          } catch (_) {
            return null;
          }
        })
        .whereType<OrderRecord>()
        .toList();
  }

  Future<void> _persist() async {
    final p = await _p;
    await p.setStringList(
        _key, notifier.value.map((o) => jsonEncode(o.toJson())).toList());
  }

  /// Insert [order], or replace the one already carrying its id.
  ///
  /// Replacing matters because an order can be re-quoted before it is paid — a
  /// coupon applied at the counter regenerates the invoice — and a second
  /// `add` would leave the first, now-wrong, pending order in the list forever.
  Future<void> upsert(OrderRecord order) async {
    final existing = notifier.value.indexWhere((o) => o.id == order.id);
    notifier.value = existing < 0
        ? [order, ...notifier.value]
        : [
            for (final o in notifier.value) o.id == order.id ? order : o,
          ];
    await _persist();
  }

  Future<void> markPaid(String id) async {
    if (!notifier.value.any((o) => o.id == id && !o.isPaid)) return;
    notifier.value = [
      for (final o in notifier.value)
        o.id == id
            ? OrderRecord.fromJson({...o.toJson(), 'isPaid': true})
            : o,
    ];
    await _persist();
  }

  Future<void> clear() async {
    notifier.value = [];
    await _persist();
  }
}

final OrdersStore ordersStore = OrdersStore();
