import 'dart:math';

import 'package:intl/intl.dart';

import 'currencies.dart';

/// Faithful port of `src/lib/formatter.ts`.

/// Decimal places used per currency (`decimalsToUse`).
int decimalsToUse(Currency currency) {
  switch (currency) {
    case Currency.sat:
    case Currency.ars:
      return 0;
    case Currency.usd:
      return 2;
  }
}

/// `roundToDown` — floor to `decimals` places with the same sign-adjustment the
/// webapp uses (keeps parity with displayed conversions).
double roundToDown(num value, int decimals) {
  final t = pow(10, decimals);
  final adjustment = (decimals > 0 ? 1 : 0) *
      (value.sign * (10 / pow(100, decimals)));
  final floored = (value * t + adjustment).floorToDouble() / t;
  return double.parse(floored.toStringAsFixed(decimals));
}

/// `formatToPreference` — locale-aware number formatting per currency.
String formatToPreference(Currency currency, num amount, {bool round = false}) {
  final maxDecimals = decimalsToUse(currency);
  final minDecimals = round ? 2 : maxDecimals;

  final locale = currency.locale.replaceAll('-', '_');
  final fmt = NumberFormat.decimalPattern(locale)
    ..minimumFractionDigits = minDecimals
    ..maximumFractionDigits = maxDecimals;
  return fmt.format(amount);
}

/// `formatAddress` — `abc…wxyz` truncation.
String formatAddress(String address, {int size = 22}) {
  if (address.isEmpty) return address;
  if (address.length <= size + 4) return address;
  return '${address.substring(0, size)}...'
      '${address.substring(address.length - 4)}';
}
