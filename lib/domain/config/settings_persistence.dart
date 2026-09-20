import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'settings_state.dart';

/// Persists prize-coupon settings only (tip/tab/relays stay in-memory).
class SettingsPersistence {
  static const _keyEnabled = 'prizePrintEnabled';
  static const _keyMode = 'prizePrintMode';
  static const _keyCoupons = 'prizeCoupons';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<void> load() async {
    final p = await _p;
    final enabled = p.getBool(_keyEnabled) ?? false;
    final modeRaw = p.getString(_keyMode);
    final mode = modeRaw == PrizePrintMode.button.name
        ? PrizePrintMode.button
        : PrizePrintMode.auto;
    final coupons = _decodeCoupons(p.getString(_keyCoupons));
    appSettings.value = appSettings.value.copyWith(
      prizePrintEnabled: enabled,
      prizePrintMode: mode,
      prizeCoupons: coupons,
    );
  }

  Future<void> savePrizeSettings(SettingsState s) async {
    final p = await _p;
    await p.setBool(_keyEnabled, s.prizePrintEnabled);
    await p.setString(_keyMode, s.prizePrintMode.name);
    await p.setString(_keyCoupons, jsonEncode(_encodeCoupons(s.prizeCoupons)));
  }

  List<PrizeCoupon> _decodeCoupons(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => PrizeCoupon.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  List<Map<String, dynamic>> _encodeCoupons(List<PrizeCoupon> coupons) =>
      coupons.map((c) => c.toJson()).toList();
}

final settingsPersistence = SettingsPersistence();

void _persistPrizeSlice() {
  settingsPersistence.savePrizeSettings(appSettings.value).ignore();
}

void setPrizePrintEnabled(bool v) {
  appSettings.value = appSettings.value.copyWith(prizePrintEnabled: v);
  _persistPrizeSlice();
}

void setPrizePrintMode(PrizePrintMode mode) {
  appSettings.value = appSettings.value.copyWith(prizePrintMode: mode);
  _persistPrizeSlice();
}

bool addPrizeCoupon(String text, int chancePercent) {
  final t = text.trim();
  if (t.isEmpty) return false;
  final chance = chancePercent.clamp(0, 100);
  final current = List<PrizeCoupon>.from(appSettings.value.prizeCoupons);
  current.add(PrizeCoupon(
    id: DateTime.now().microsecondsSinceEpoch.toString(),
    text: t,
    chancePercent: chance,
  ));
  appSettings.value = appSettings.value.copyWith(prizeCoupons: current);
  _persistPrizeSlice();
  return true;
}

bool updatePrizeCoupon(String id, String text, int chancePercent) {
  final t = text.trim();
  if (t.isEmpty) return false;
  final chance = chancePercent.clamp(0, 100);
  final current = List<PrizeCoupon>.from(appSettings.value.prizeCoupons);
  final i = current.indexWhere((c) => c.id == id);
  if (i < 0) return false;
  current[i] = current[i].copyWith(text: t, chancePercent: chance);
  appSettings.value = appSettings.value.copyWith(prizeCoupons: current);
  _persistPrizeSlice();
  return true;
}

void removePrizeCoupon(String id) {
  final current = List<PrizeCoupon>.from(appSettings.value.prizeCoupons)
    ..removeWhere((c) => c.id == id);
  appSettings.value = appSettings.value.copyWith(prizeCoupons: current);
  _persistPrizeSlice();
}
