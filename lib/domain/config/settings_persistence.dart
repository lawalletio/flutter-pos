import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/sounds.dart';
import 'settings_state.dart';

/// Persists prize-coupon settings only (tip/tab/relays stay in-memory).
class SettingsPersistence {
  static const _keyEnabled = 'prizePrintEnabled';
  static const _keyMode = 'prizePrintMode';
  static const _keyCoupons = 'prizeCoupons';
  static const _keyPaidSound = 'paidSoundId';
  static const _keySoundEnabled = 'soundEnabled';
  static const _keySoundVolume = 'soundVolume';
  static const _keyTouchVolume = 'touchVolume';
  static const _keyPaidVolume = 'paidVolume';
  static const _keyWheelDuration = 'wheelDurationMs';
  static const _keyWheelOffer = 'wheelOffer';
  static const _keyWheelSpeed = 'wheelSpeed';
  static const _keyWheelAcceleration = 'wheelAcceleration';
  static const _keyWheelPracticePrint = 'wheelPracticePrint';

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
    final paidSoundId = paidSoundById(p.getString(_keyPaidSound)).id;
    appSettings.value = appSettings.value.copyWith(
      prizePrintEnabled: enabled,
      prizePrintMode: mode,
      prizeCoupons: coupons,
      paidSoundId: paidSoundId,
      soundEnabled: p.getBool(_keySoundEnabled) ?? true,
      soundVolume: _unit(p.getDouble(_keySoundVolume)),
      touchVolume: _unit(p.getDouble(_keyTouchVolume)),
      paidVolume: _unit(p.getDouble(_keyPaidVolume)),
      wheelDurationMs: clampWheelDurationMs(
        p.getInt(_keyWheelDuration) ?? kWheelDurationDefaultMs,
      ),
      wheelOffer: p.getString(_keyWheelOffer) == WheelOffer.always.name
          ? WheelOffer.always
          : WheelOffer.tipOnly,
      wheelSpeed: clampWheelPace(p.getDouble(_keyWheelSpeed) ?? 1),
      wheelAcceleration: clampWheelPace(p.getDouble(_keyWheelAcceleration) ?? 1),
      wheelPracticePrint: p.getBool(_keyWheelPracticePrint) ?? false,
    );
  }

  double _unit(double? value) {
    if (value == null || value.isNaN) return 1;
    return value.clamp(0.0, 1.0);
  }

  Future<void> saveSoundMix(SettingsState s) async {
    final p = await _p;
    await p.setBool(_keySoundEnabled, s.soundEnabled);
    await p.setDouble(_keySoundVolume, s.soundVolume);
    await p.setDouble(_keyTouchVolume, s.touchVolume);
    await p.setDouble(_keyPaidVolume, s.paidVolume);
  }

  Future<void> savePaidSound(String id) async {
    final p = await _p;
    await p.setString(_keyPaidSound, id);
  }

  Future<void> savePrizeSettings(SettingsState s) async {
    final p = await _p;
    await p.setBool(_keyEnabled, s.prizePrintEnabled);
    await p.setString(_keyMode, s.prizePrintMode.name);
    await p.setString(_keyCoupons, jsonEncode(_encodeCoupons(s.prizeCoupons)));
    await p.setInt(_keyWheelDuration, s.wheelDurationMs);
    await p.setString(_keyWheelOffer, s.wheelOffer.name);
    await p.setDouble(_keyWheelSpeed, s.wheelSpeed);
    await p.setDouble(_keyWheelAcceleration, s.wheelAcceleration);
    await p.setBool(_keyWheelPracticePrint, s.wheelPracticePrint);
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

Future<void> _prizeWrites = Future<void>.value();

void _persistPrizeSlice() {
  final snapshot = appSettings.value;
  _prizeWrites = _prizeWrites.then((_) async {
    try {
      await settingsPersistence.savePrizeSettings(snapshot);
    } catch (_) {}
  });
}

/// Finishes the prize-settings writes already queued. Tests use this so a
/// reload cannot race an in-flight save.
Future<void> flushPrizeSettings() => _prizeWrites;

void setPaidSound(String id) {
  appSettings.value = appSettings.value.copyWith(paidSoundId: id);
  settingsPersistence.savePaidSound(id).ignore();
}

void _persistSoundMix() {
  settingsPersistence.saveSoundMix(appSettings.value).ignore();
}

double _unitVolume(double value) => value.clamp(0.0, 1.0);

void setSoundEnabled(bool v) {
  appSettings.value = appSettings.value.copyWith(soundEnabled: v);
  _persistSoundMix();
  if (v) AppSounds.play(AppSound.button);
}

void setSoundVolume(double v, {bool persist = true}) {
  appSettings.value = appSettings.value.copyWith(soundVolume: _unitVolume(v));
  if (persist) _persistSoundMix();
}

void setTouchVolume(double v, {bool persist = true}) {
  appSettings.value = appSettings.value.copyWith(touchVolume: _unitVolume(v));
  if (persist) _persistSoundMix();
}

void setPaidVolume(double v, {bool persist = true}) {
  appSettings.value = appSettings.value.copyWith(paidVolume: _unitVolume(v));
  if (persist) _persistSoundMix();
}

void setWheelOffer(WheelOffer offer) {
  appSettings.value = appSettings.value.copyWith(wheelOffer: offer);
  _persistPrizeSlice();
}

void setWheelDuration(int milliseconds, {bool persist = true}) {
  appSettings.value = appSettings.value
      .copyWith(wheelDurationMs: clampWheelDurationMs(milliseconds));
  if (persist) _persistPrizeSlice();
}

void setWheelSpeed(double value, {bool persist = true}) {
  appSettings.value = appSettings.value.copyWith(wheelSpeed: clampWheelPace(value));
  if (persist) _persistPrizeSlice();
}

void setWheelAcceleration(double value, {bool persist = true}) {
  appSettings.value =
      appSettings.value.copyWith(wheelAcceleration: clampWheelPace(value));
  if (persist) _persistPrizeSlice();
}

void setWheelPracticePrint(bool value) {
  appSettings.value = appSettings.value.copyWith(wheelPracticePrint: value);
  _persistPrizeSlice();
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
