import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'currencies.dart';

const _key = 'selectedCurrency';

/// The currency last picked on any switcher (amount entry, invoice). Every
/// switcher reads and writes this one, so the choice follows the cashier
/// across screens and restarts. Device-wide, not per merchant.
final selectedCurrency = ValueNotifier<Currency>(Currency.ars);

Future<void> loadSelectedCurrency() async {
  final code = (await SharedPreferences.getInstance()).getString(_key);
  selectedCurrency.value =
      (code == null ? null : CurrencyX.tryFromCode(code)) ?? Currency.ars;
}

Future<void> setSelectedCurrency(Currency c) async {
  selectedCurrency.value = c;
  await (await SharedPreferences.getInstance()).setString(_key, c.code);
}
