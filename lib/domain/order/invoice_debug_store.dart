import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'current_order.dart';

/// One bolt11 the provider actually returned, kept even when the payment screen
/// later replaced it. The orders list only stores the invoice still on screen,
/// so a paid-but-replaced invoice would otherwise disappear.
@immutable
class GeneratedInvoice {
  final String id;
  final int createdAt;
  final String invoice;
  final String? verifyUrl;
  final String? zapPubkey;
  final List<String> zapRelays;
  final String? zapOrderId;
  final int amountSats;
  final String summary;
  final List<OrderItem> items;
  final String? couponId;
  final String? couponName;
  final int discountSats;
  final String reason;
  final int generation;
  final int latestGeneration;
  final int screenId;
  final int liveScreens;

  /// This reply was copied onto the payment screen.
  final bool applied;

  /// A newer request had already started when this reply arrived. The screen
  /// still applies it, so a slow reply can replace the invoice on the QR.
  final bool stale;

  final String? orderId;
  final bool? lastSettled;
  final int? lastCheckedAt;

  const GeneratedInvoice({
    required this.id,
    required this.createdAt,
    required this.invoice,
    required this.amountSats,
    required this.summary,
    required this.reason,
    required this.generation,
    required this.latestGeneration,
    required this.screenId,
    required this.liveScreens,
    required this.applied,
    required this.stale,
    this.verifyUrl,
    this.zapPubkey,
    this.zapRelays = const [],
    this.zapOrderId,
    this.items = const [],
    this.couponId,
    this.couponName,
    this.discountSats = 0,
    this.orderId,
    this.lastSettled,
    this.lastCheckedAt,
  });

  bool get supportsLud21 => verifyUrl != null && verifyUrl!.isNotEmpty;
  bool get supportsNip57 =>
      zapPubkey != null &&
      zapPubkey!.isNotEmpty &&
      invoice.isNotEmpty &&
      zapRelays.isNotEmpty;

  GeneratedInvoice copyWith({bool? lastSettled, int? lastCheckedAt}) =>
      GeneratedInvoice(
        id: id,
        createdAt: createdAt,
        invoice: invoice,
        verifyUrl: verifyUrl,
        zapPubkey: zapPubkey,
        zapRelays: zapRelays,
        zapOrderId: zapOrderId,
        amountSats: amountSats,
        summary: summary,
        items: items,
        couponId: couponId,
        couponName: couponName,
        discountSats: discountSats,
        reason: reason,
        generation: generation,
        latestGeneration: latestGeneration,
        screenId: screenId,
        liveScreens: liveScreens,
        applied: applied,
        stale: stale,
        orderId: orderId,
        lastSettled: lastSettled ?? this.lastSettled,
        lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt,
        'invoice': invoice,
        'verifyUrl': verifyUrl,
        'zapPubkey': zapPubkey,
        'zapRelays': zapRelays,
        'zapOrderId': zapOrderId,
        'amountSats': amountSats,
        'summary': summary,
        'items': items.map((it) => it.toJson()).toList(),
        if (couponId != null) 'couponId': couponId,
        if (couponName != null) 'couponName': couponName,
        if (discountSats > 0) 'discountSats': discountSats,
        'reason': reason,
        'generation': generation,
        'latestGeneration': latestGeneration,
        'screenId': screenId,
        'liveScreens': liveScreens,
        'applied': applied,
        'stale': stale,
        'orderId': orderId,
        'lastSettled': lastSettled,
        'lastCheckedAt': lastCheckedAt,
      };

  factory GeneratedInvoice.fromJson(Map<String, dynamic> j) => GeneratedInvoice(
        id: j['id'] as String,
        createdAt: (j['createdAt'] as num).toInt(),
        invoice: j['invoice'] as String? ?? '',
        verifyUrl: j['verifyUrl'] as String?,
        zapPubkey: j['zapPubkey'] as String?,
        zapRelays: (j['zapRelays'] as List?)?.map((e) => e.toString()).toList() ??
            const [],
        zapOrderId: j['zapOrderId'] as String?,
        amountSats: (j['amountSats'] as num?)?.toInt() ?? 0,
        summary: j['summary'] as String? ?? '',
        items: (j['items'] as List?)
                ?.map((e) => OrderItem.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        couponId: j['couponId'] as String?,
        couponName: j['couponName'] as String?,
        discountSats: (j['discountSats'] as num?)?.toInt() ?? 0,
        reason: j['reason'] as String? ?? '',
        generation: (j['generation'] as num?)?.toInt() ?? 0,
        latestGeneration: (j['latestGeneration'] as num?)?.toInt() ?? 0,
        screenId: (j['screenId'] as num?)?.toInt() ?? 0,
        liveScreens: (j['liveScreens'] as num?)?.toInt() ?? 1,
        applied: j['applied'] == true,
        stale: j['stale'] == true,
        orderId: j['orderId'] as String?,
        lastSettled: j['lastSettled'] as bool?,
        lastCheckedAt: (j['lastCheckedAt'] as num?)?.toInt(),
      );
}

/// Every invoice the provider returned, newest first. Cleared only by the
/// debug screen. Capped so a long shift cannot grow the preference without bound.
class InvoiceDebugStore {
  static const _key = 'invoiceDebugLog';
  static const _max = 200;

  final ValueNotifier<List<GeneratedInvoice>> notifier =
      ValueNotifier<List<GeneratedInvoice>>([]);
  SharedPreferences? _prefs;

  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<void> load() async {
    final p = await _p;
    final raw = p.getStringList(_key) ?? const [];
    notifier.value = raw
        .map((s) {
          try {
            return GeneratedInvoice.fromJson(
                jsonDecode(s) as Map<String, dynamic>);
          } catch (_) {
            return null;
          }
        })
        .whereType<GeneratedInvoice>()
        .toList();
  }

  Future<void> _persist() async {
    final p = await _p;
    await p.setStringList(
        _key, notifier.value.map((e) => jsonEncode(e.toJson())).toList());
  }

  Future<void> add(GeneratedInvoice entry) async {
    final next = [entry, ...notifier.value];
    notifier.value = next.length > _max ? next.sublist(0, _max) : next;
    await _persist();
  }

  Future<void> markChecked(String id, bool settled) async {
    final at = DateTime.now().millisecondsSinceEpoch;
    notifier.value = [
      for (final e in notifier.value)
        e.id == id ? e.copyWith(lastSettled: settled, lastCheckedAt: at) : e,
    ];
    await _persist();
  }

  Future<void> clear() async {
    notifier.value = [];
    await _persist();
  }
}

final InvoiceDebugStore invoiceDebugStore = InvoiceDebugStore();
