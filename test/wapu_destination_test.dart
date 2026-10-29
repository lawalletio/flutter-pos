import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/features/wapu/wapu_destination.dart';

void main() {
  test('normalizes case, spaces and the lightning: prefix', () {
    expect(
      normalizeDestination('  LIGHTNING:Alice@Example.COM '),
      'alice@example.com',
    );
  });

  test('accepts backend-valid addresses', () {
    expect(isWapuLightningAddress('alice@walletofsatoshi.com'), isTrue);
    expect(isWapuLightningAddress('a.b-c_d+e@sub.example.co'), isTrue);
    // The 64-char local part is the longest the backend takes.
    expect(isWapuLightningAddress('${'a' * 64}@example.com'), isTrue);
  });

  test('rejects addresses the backend rejects', () {
    for (final bad in [
      'alice',
      'a@b@example.com',
      'alice@localhost',
      'alice@example.c0m',
      'al ice@example.com',
      '${'a' * 65}@example.com',
      'alice@-bad.com',
    ]) {
      expect(isWapuLightningAddress(bad), isFalse, reason: bad);
    }
  });

  test('classifies invoices and lnurls', () {
    expect(classifyDestination('lightning:LNBC10U1P3XYZ'),
        DestinationKind.invoice);
    expect(classifyDestination('lntb1500n1pxyz'), DestinationKind.invoice);
    expect(classifyDestination('LNURL1DP68GURN8GHJ7'), DestinationKind.lnurl);
    expect(classifyDestination(' Alice@Example.com '),
        DestinationKind.lightningAddress);
    expect(classifyDestination('hello'), DestinationKind.invalid);
  });

  test('keeps an address whose name starts like an invoice or lnurl', () {
    // The backend accepts these, and bech32 strings never contain an @.
    expect(classifyDestination('lnurl@example.com'),
        DestinationKind.lightningAddress);
    expect(classifyDestination('lnbc@example.com'),
        DestinationKind.lightningAddress);
  });
}
