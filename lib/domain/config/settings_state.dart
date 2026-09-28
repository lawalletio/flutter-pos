import 'package:flutter/foundation.dart';

/// Lightweight app-wide settings store for the preview (tip/tab gates + relays).
/// Production will move this into a Riverpod + persistence layer; a [ValueNotifier]
/// keeps the preview simple while making toggles actually affect other screens.

const List<String> kDefaultRelays = [
  'wss://relay.lacrypta.ar',
  'wss://relay.damus.io',
  'wss://nostr-pub.wellorder.net',
];

/// Suggested relays offered in Settings (mirrors `SUGGESTED_NOSTR_RELAYS`).
const List<String> kSuggestedRelays = [
  'wss://relay.lacrypta.ar',
  'wss://relay.damus.io',
  'wss://nostr-pub.wellorder.net',
  'wss://relay.nostr.band',
  'wss://relay.wellorder.net',
  'wss://relay.primal.net',
  'wss://relay.masize.com',
];

enum PrizePrintMode { auto, button }

/// When the success screen offers the fortune wheel.
enum WheelOffer { always, tipOnly }

/// Wheel spin length the merchant can pick in Coupons. Whole seconds.
const kWheelDurationMinMs = 2000;
const kWheelDurationMaxMs = 15000;
const kWheelDurationDefaultMs = 6000;

const kWheelPaceMin = 0.5;
const kWheelPaceMax = 2.0;

double clampWheelPace(double value) {
  if (value.isNaN) return 1;
  return value.clamp(kWheelPaceMin, kWheelPaceMax);
}

int clampWheelDurationMs(int milliseconds) =>
    milliseconds.clamp(kWheelDurationMinMs, kWheelDurationMaxMs);

@immutable
class PrizeCoupon {
  final String id;
  final String text;
  final int chancePercent;

  const PrizeCoupon({
    required this.id,
    required this.text,
    required this.chancePercent,
  });

  PrizeCoupon copyWith({String? id, String? text, int? chancePercent}) =>
      PrizeCoupon(
        id: id ?? this.id,
        text: text ?? this.text,
        chancePercent: chancePercent ?? this.chancePercent,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'chancePercent': chancePercent,
      };

  factory PrizeCoupon.fromJson(Map<String, dynamic> json) => PrizeCoupon(
        id: json['id'] as String? ?? '',
        text: json['text'] as String? ?? '',
        chancePercent: (json['chancePercent'] as num?)?.toInt() ?? 0,
      );
}

@immutable
class SettingsState {
  final bool tipEnabled;
  final bool tabEnabled;
  final List<String> relays;
  final String languageCode; // 'es' | 'en'
  final bool prizePrintEnabled;
  final PrizePrintMode prizePrintMode;
  final List<PrizeCoupon> prizeCoupons;
  final String paidSoundId;
  final bool soundEnabled;

  /// Master level, 0–1. Touch and payment cues multiply this by their own level.
  final double soundVolume;
  final double touchVolume;
  final double paidVolume;

  /// How long the fortune wheel spins, in milliseconds.
  final int wheelDurationMs;

  /// Multiplier on the wheel's cruise speed. 1 is the default pace.
  final double wheelSpeed;

  /// How hard the wheel launches and then settles. 1 is the default curve.
  final double wheelAcceleration;

  /// When trying the wheel from settings, print the winning ticket.
  final bool wheelPracticePrint;

  /// [WheelOffer.tipOnly] shows the spin button only after a tip.
  final WheelOffer wheelOffer;

  const SettingsState({
    this.tipEnabled = false, // webapp default: off
    this.tabEnabled = false, // webapp default: off
    this.relays = kDefaultRelays,
    this.languageCode = 'es',
    this.prizePrintEnabled = false,
    this.prizePrintMode = PrizePrintMode.auto,
    this.prizeCoupons = const [],
    this.paidSoundId = 'arpeggio',
    this.soundEnabled = true,
    this.soundVolume = 1,
    this.touchVolume = 1,
    this.paidVolume = 1,
    this.wheelDurationMs = kWheelDurationDefaultMs,
    this.wheelSpeed = 1,
    this.wheelAcceleration = 1,
    this.wheelPracticePrint = false,
    this.wheelOffer = WheelOffer.tipOnly,
  });

  SettingsState copyWith({
    bool? tipEnabled,
    bool? tabEnabled,
    List<String>? relays,
    String? languageCode,
    bool? prizePrintEnabled,
    PrizePrintMode? prizePrintMode,
    List<PrizeCoupon>? prizeCoupons,
    String? paidSoundId,
    bool? soundEnabled,
    double? soundVolume,
    double? touchVolume,
    double? paidVolume,
    int? wheelDurationMs,
    double? wheelSpeed,
    double? wheelAcceleration,
    bool? wheelPracticePrint,
    WheelOffer? wheelOffer,
  }) =>
      SettingsState(
        tipEnabled: tipEnabled ?? this.tipEnabled,
        tabEnabled: tabEnabled ?? this.tabEnabled,
        relays: relays ?? this.relays,
        languageCode: languageCode ?? this.languageCode,
        prizePrintEnabled: prizePrintEnabled ?? this.prizePrintEnabled,
        prizePrintMode: prizePrintMode ?? this.prizePrintMode,
        prizeCoupons: prizeCoupons ?? this.prizeCoupons,
        paidSoundId: paidSoundId ?? this.paidSoundId,
        soundEnabled: soundEnabled ?? this.soundEnabled,
        soundVolume: soundVolume ?? this.soundVolume,
        touchVolume: touchVolume ?? this.touchVolume,
        paidVolume: paidVolume ?? this.paidVolume,
        wheelDurationMs: wheelDurationMs ?? this.wheelDurationMs,
        wheelSpeed: wheelSpeed ?? this.wheelSpeed,
        wheelAcceleration: wheelAcceleration ?? this.wheelAcceleration,
        wheelPracticePrint: wheelPracticePrint ?? this.wheelPracticePrint,
        wheelOffer: wheelOffer ?? this.wheelOffer,
      );
}

/// Global singleton settings notifier used across the preview screens.
final ValueNotifier<SettingsState> appSettings =
    ValueNotifier<SettingsState>(const SettingsState());

void setTipEnabled(bool v) =>
    appSettings.value = appSettings.value.copyWith(tipEnabled: v);
void setTabEnabled(bool v) =>
    appSettings.value = appSettings.value.copyWith(tabEnabled: v);
void setLanguage(String code) =>
    appSettings.value = appSettings.value.copyWith(languageCode: code);

/// Normalize a relay URL to `wss://…` with no trailing slash (mirrors the
/// webapp's `cleanRelays`). Returns null if it can't form a valid host.
String? normalizeRelay(String input) {
  var s = input.trim();
  if (s.isEmpty) return null;
  s = s.replaceFirst(RegExp(r'^(https?|wss?)://', caseSensitive: false), '');
  s = s.replaceAll(RegExp(r'/+$'), '');
  if (s.isEmpty || !s.contains('.')) return null;
  return 'wss://$s';
}

void toggleRelay(String relay) {
  final current = List<String>.from(appSettings.value.relays);
  if (current.contains(relay)) {
    if (current.length <= 1) return; // keep at least one (webapp guard)
    current.remove(relay);
  } else {
    current.add(relay);
  }
  appSettings.value = appSettings.value.copyWith(relays: current);
}

/// Add a custom relay. Returns false if invalid or already present.
bool addRelay(String input) {
  final url = normalizeRelay(input);
  if (url == null) return false;
  final current = List<String>.from(appSettings.value.relays);
  if (current.contains(url)) return false;
  current.add(url);
  appSettings.value = appSettings.value.copyWith(relays: current);
  return true;
}

/// Edit the relay at [index] in place. Returns false if invalid/duplicate.
bool updateRelay(int index, String input) {
  final url = normalizeRelay(input);
  if (url == null) return false;
  final current = List<String>.from(appSettings.value.relays);
  if (index < 0 || index >= current.length) return false;
  if (current.contains(url) && current[index] != url) return false;
  current[index] = url;
  appSettings.value = appSettings.value.copyWith(relays: current);
  return true;
}

void removeRelay(String relay) {
  final current = List<String>.from(appSettings.value.relays);
  if (current.length <= 1) return; // keep at least one
  current.remove(relay);
  appSettings.value = appSettings.value.copyWith(relays: current);
}

void resetRelays() =>
    appSettings.value = appSettings.value.copyWith(relays: kDefaultRelays);
