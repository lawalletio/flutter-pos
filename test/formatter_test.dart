import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/domain/config/currencies.dart';
import 'package:lawallet_pos/domain/config/formatter.dart';

void main() {
  group('decimalsToUse', () {
    test('SAT and ARS use 0, USD uses 2', () {
      expect(decimalsToUse(Currency.sat), 0);
      expect(decimalsToUse(Currency.ars), 0);
      expect(decimalsToUse(Currency.usd), 2);
    });
  });

  group('roundToDown (parity with lib/formatter.ts)', () {
    test('floors positive values at given decimals', () {
      expect(roundToDown(1.23456, 2), 1.23);
      expect(roundToDown(1.239, 2), 1.23);
      expect(roundToDown(1234.5, 0), 1234.0);
      expect(roundToDown(0, 2), 0.0);
    });

    test('negative values floor toward -infinity (sign-adjusted)', () {
      expect(roundToDown(-1.239, 2), -1.24);
    });
  });

  group('formatToPreference', () {
    test('SAT groups with es-AR separators, no decimals', () {
      expect(formatToPreference(Currency.sat, 1500000), '1.500.000');
    });

    test('USD uses en-US with 2 decimals', () {
      expect(formatToPreference(Currency.usd, 3.72), '3.72');
    });
  });

  group('formatAddress', () {
    test('truncates long addresses', () {
      expect(formatAddress('a' * 40), '${'a' * 22}...aaaa');
    });
    test('leaves short addresses intact', () {
      expect(formatAddress('short'), 'short');
    });
  });
}
