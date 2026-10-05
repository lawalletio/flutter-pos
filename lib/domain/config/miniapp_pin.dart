import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _key = 'miniappPin';

/// The PIN that closes a miniapp (kiosk mode) and opens the PIN settings.
/// Device-wide, not per merchant. Null until someone sets one, and while it
/// is null nothing asks for it.
// ponytail: stored in plain prefs; it guards a kiosk screen, not money.
final miniappPin = ValueNotifier<String?>(null);

Future<void> loadMiniappPin() async {
  miniappPin.value = (await SharedPreferences.getInstance()).getString(_key);
}

Future<void> setMiniappPin(String pin) async {
  miniappPin.value = pin;
  await (await SharedPreferences.getInstance()).setString(_key, pin);
}
