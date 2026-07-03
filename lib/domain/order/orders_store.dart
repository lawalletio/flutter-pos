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
  });

  DateTime get createdAtDate => DateTime.fromMillisecondsSinceEpoch(createdAt);

  bool get supportsLud21 => verifyUrl != null && verifyUrl!.isNotEmpty;
  bool get supportsNip57 =>
      zapPubkey != null &&
      zapPubkey!.isNotEmpty &&
      (invoice?.isNotEmpty ?? false) &&
      zapRelays.isNotEmpty;
  bool get canRecheck => supportsLud21 || supportsNip57;

  OrderRecord copyWith({bool? isPaid}) => OrderRecord(
        id: id,
        createdAt: createdAt,
        amountSats: amountSats,
        summary: summary,
        isPaid: isPaid ?? this.isPaid,
        verifyUrl: verifyUrl,
        invoice: invoice,
        zapPubkey: zapPubkey,
        zapRelays: zapRelays,
        zapOrderId: zapOrderId,
        items: items,
      );

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
      };

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

  Future<void> add(OrderRecord order) async {
    notifier.value = [order, ...notifier.value];
    await _persist();
  }

  Future<void> markPaid(String id) async {
    if (!notifier.value.any((o) => o.id == id && !o.isPaid)) return;
    notifier.value = [
      for (final o in notifier.value)
        o.id == id ? o.copyWith(isPaid: true) : o,
    ];
    await _persist();
  }

  Future<void> clear() async {
    notifier.value = [];
    await _persist();
  }
}

final OrdersStore ordersStore = OrdersStore();
