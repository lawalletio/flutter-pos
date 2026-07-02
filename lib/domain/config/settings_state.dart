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

@immutable
class SettingsState {
  final bool tipEnabled;
  final bool tabEnabled;
  final List<String> relays;
  final String languageCode; // 'es' | 'en'

  const SettingsState({
    this.tipEnabled = false, // webapp default: off
    this.tabEnabled = false, // webapp default: off
    this.relays = kDefaultRelays,
    this.languageCode = 'es',
  });

  SettingsState copyWith({
    bool? tipEnabled,
    bool? tabEnabled,
    List<String>? relays,
    String? languageCode,
  }) =>
      SettingsState(
        tipEnabled: tipEnabled ?? this.tipEnabled,
        tabEnabled: tabEnabled ?? this.tabEnabled,
        relays: relays ?? this.relays,
        languageCode: languageCode ?? this.languageCode,
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
