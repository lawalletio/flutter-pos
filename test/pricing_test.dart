import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/data/pricing/pricing_service.dart';
import 'package:lawallet_pos/domain/config/currencies.dart';

void main() {
  group('PricingService conversion (fiat per sat)', () {
    final p = PricingService();
    // e.g. BTC.ARS = 94_000_000 → 0.94 ARS/sat; BTC.USD = 60_000 → 0.0006 USD/sat
    p.notifier.value = const Rates(0.94, 0.0006);

    test('fiatToSats divides by the per-sat rate', () {
      expect(p.fiatToSats(0.94, Currency.ars), 1);
      expect(p.fiatToSats(9.4, Currency.ars), 10);
      expect(p.fiatToSats(0.0006, Currency.usd), 1);
    });

    test('satsToFiat multiplies by the per-sat rate', () {
      expect(p.satsToFiat(100, Currency.ars), closeTo(94, 1e-9));
      expect(p.satsToFiat(1000, Currency.usd), closeTo(0.6, 1e-9));
    });

    test('SAT is a passthrough', () {
      expect(p.fiatToSats(2100, Currency.sat), 2100);
      expect(p.satsToFiat(2100, Currency.sat), 2100.0);
    });

    test('round-trips within rounding', () {
      final sats = p.fiatToSats(5000, Currency.ars)!;
      expect(p.satsToFiat(sats, Currency.ars), closeTo(5000, 1));
    });
  });

  group('PricingService without loaded rates', () {
    final q = PricingService();
    test('fiat conversions return null, SAT still works', () {
      expect(q.fiatToSats(100, Currency.ars), isNull);
      expect(q.satsToFiat(100, Currency.ars), isNull);
      expect(q.fiatToSats(100, Currency.sat), 100);
      expect(q.satsToFiat(100, Currency.sat), 100.0);
    });
  });
}
