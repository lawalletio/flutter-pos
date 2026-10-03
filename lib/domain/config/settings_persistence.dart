import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/sounds.dart';
import 'session.dart';
import 'settings_state.dart';

/// Persists the till (tip, coupons, wheel) per Lightning address. Sound stays global.
class SettingsPersistence {
  static const _keyPaidSound = 'paidSoundId';
  static const _keySoundEnabled = 'soundEnabled';
  static const _keySoundVolume = 'soundVolume';
  static const _keyTouchVolume = 'touchVolume';
  static const _keyPaidVolume = 'paidVolume';
  static const _keyTillByAddress = 'tillSettingsByAddress';

  SharedPreferences? _prefs;
  final Map<String, MerchantTillSettings> _byAddress = {};
  String _boundAddress = '';
  bool _ready = false;
  bool _listening = false;

  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// Drops the cached preferences handle so a test can install a fresh mock.
  void debugForgetPrefs() {
    _prefs = null;
    _byAddress.clear();
  }

  Future<void> load() async {
    assert(_tillPersistenceHooked);
    _ensureListening();
    final p = await _p;
    _byAddress
      ..clear()
      ..addAll(_decodeTillMap(p.getString(_keyTillByAddress)));
    final paidSoundId = paidSoundById(p.getString(_keyPaidSound)).id;
    appSettings.value = const SettingsState().copyWith(
      relays: appSettings.value.relays,
      languageCode: appSettings.value.languageCode,
      tabEnabled: appSettings.value.tabEnabled,
      paidSoundId: paidSoundId,
      soundEnabled: p.getBool(_keySoundEnabled) ?? true,
      soundVolume: _unit(p.getDouble(_keySoundVolume)),
      touchVolume: _unit(p.getDouble(_keyTouchVolume)),
      paidVolume: _unit(p.getDouble(_keyPaidVolume)),
    );
    _ready = true;
    _boundAddress = '';
    _onAddress();
  }

  void _ensureListening() {
    if (_listening) return;
    _listening = true;
    merchantAddress.addListener(_onAddress);
  }

  void _onAddress() {
    if (!_ready) return;
    final next = merchantAddress.value.trim().toLowerCase();
    if (next == _boundAddress) return;
    if (_boundAddress.isNotEmpty) {
      _byAddress[_boundAddress] =
          MerchantTillSettings.fromSettings(appSettings.value);
      _queueTillSave();
    }
    _boundAddress = next;
    final till = next.isEmpty
        ? const MerchantTillSettings()
        : (_byAddress[next] ?? const MerchantTillSettings());
    appSettings.value = till.applyTo(appSettings.value);
  }

  Map<String, MerchantTillSettings> _decodeTillMap(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map(
        (key, value) => MapEntry(
          key,
          MerchantTillSettings.fromJson(value as Map<String, dynamic>),
        ),
      );
    } catch (_) {
      return {};
    }
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

  Future<void> savePrizeSettings(String address, SettingsState s) async {
    if (address.isNotEmpty) {
      _byAddress[address] = MerchantTillSettings.fromSettings(s);
    }
    final p = await _p;
    await p.setString(_keyTillByAddress, jsonEncode(_tillJson()));
  }

  String get boundAddress => _boundAddress;

  void _queueTillSave() {
    final raw = jsonEncode(_tillJson());
    _prizeWrites = _prizeWrites.then((_) async {
      try {
        final p = await _p;
        await p.setString(_keyTillByAddress, raw);
      } catch (_) {}
    });
  }

  Map<String, dynamic> _tillJson() =>
      _byAddress.map((key, value) => MapEntry(key, value.toJson()));
}

final settingsPersistence = SettingsPersistence();

Future<void> _prizeWrites = Future<void>.value();

void _persistPrizeSlice() {
  final address = settingsPersistence.boundAddress;
  final snapshot = appSettings.value;
  _prizeWrites = _prizeWrites.then((_) async {
    try {
      await settingsPersistence.savePrizeSettings(address, snapshot);
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

final bool _tillPersistenceHooked = () {
  persistTillSettings = _persistPrizeSlice;
  return true;
}();
