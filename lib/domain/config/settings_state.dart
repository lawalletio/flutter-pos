import 'package:flutter/foundation.dart';

/// Lightweight app-wide settings store for the preview (tip/tab gates + relays).
/// Production will move this into a Riverpod + persistence layer; a [ValueNotifier]
/// keeps the preview simple while making toggles actually affect other screens.

const List<String> kDefaultRelays = [
  'wss://relay.damus.io',
  'wss://nostr-pub.wellorder.net',
];

/// Suggested relays offered in Settings (mirrors `SUGGESTED_NOSTR_RELAYS`).
const List<String> kSuggestedRelays = [
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

  const SettingsState({
    this.tipEnabled = false, // webapp default: off
    this.tabEnabled = false, // webapp default: off
    this.relays = kDefaultRelays,
  });

  SettingsState copyWith({
    bool? tipEnabled,
    bool? tabEnabled,
    List<String>? relays,
  }) =>
      SettingsState(
        tipEnabled: tipEnabled ?? this.tipEnabled,
        tabEnabled: tabEnabled ?? this.tabEnabled,
        relays: relays ?? this.relays,
      );
}

/// Global singleton settings notifier used across the preview screens.
final ValueNotifier<SettingsState> appSettings =
    ValueNotifier<SettingsState>(const SettingsState());

void setTipEnabled(bool v) =>
    appSettings.value = appSettings.value.copyWith(tipEnabled: v);
void setTabEnabled(bool v) =>
    appSettings.value = appSettings.value.copyWith(tabEnabled: v);
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

void resetRelays() =>
    appSettings.value = appSettings.value.copyWith(relays: kDefaultRelays);
