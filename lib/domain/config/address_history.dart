import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// History of merchant Lightning Addresses that have been used, persisted to
/// localStorage (via shared_preferences). Most-recently-used first.
class AddressHistory {
  static const _key = 'addressHistory';

  final ValueNotifier<List<String>> notifier = ValueNotifier<List<String>>([]);
  SharedPreferences? _prefs;

  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<void> load() async {
    final p = await _p;
    notifier.value = p.getStringList(_key) ?? [];
  }

  /// Record an address as used — dedup + move to the front.
  Future<void> add(String address) async {
    final a = address.trim().toLowerCase();
    if (a.isEmpty) return;
    final list = List<String>.from(notifier.value)..remove(a);
    list.insert(0, a);
    notifier.value = list;
    final p = await _p;
    await p.setStringList(_key, list);
  }

  /// Remove an address from the history.
  Future<void> remove(String address) async {
    final list = List<String>.from(notifier.value)..remove(address);
    notifier.value = list;
    final p = await _p;
    await p.setStringList(_key, list);
  }
}

final AddressHistory addressHistory = AddressHistory();
