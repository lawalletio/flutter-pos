import 'package:bech32/bech32.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/features/wapu/wapu_destination.dart';

/// The clock every invoice is read at, so its life is the same on any day.
final _now = DateTime.utc(2026, 10, 29, 15, 0);

/// The 5-bit words of [n], the most significant first: [count] of them, or the
/// fewest that hold it.
List<int> _words(int n, [int? count]) {
  count ??= (n.bitLength + 4) ~/ 5;
  return [for (var i = count - 1; i >= 0; i--) (n >> (5 * i)) & 31];
}

/// A BOLT11 invoice as a wallet makes it, but for the signature, which the
/// decoder does not check. [hrp] is the network and the amount (`lnbc25u` is
/// 2,500 sats), [made] when it was made, and [life] the seconds of its `x`
/// field, which is left out when null.
String _invoice(String hrp, {DateTime? made, int? life}) {
  // A field is its type, its length in two words, and its words.
  List<int> field(int type, List<int> data) =>
      [type, ..._words(data.length, 2), ...data];
  return Bech32Codec().encode(
    Bech32(hrp, [
      ..._words((made ?? _now).millisecondsSinceEpoch ~/ 1000, 7),
      ...field(1, List.filled(52, 0)), // `p`: the payment hash
      if (life != null) ...field(6, _words(life)), // `x`: the expiry
      ...List.filled(104, 0), // the signature
    ]),
    4000,
  );
}

/// What [parseWapuInvoice] throws for each problem, in Spanish.
const _invalid = 'El invoice no es válido';
const _notMainnet = 'El invoice no es de la red principal de Bitcoin';
const _noAmount = 'El invoice no tiene monto. Pedile al cliente uno con monto.';
const _expiresSoon =
    'El invoice vence en menos de 15 minutos. Pedile al cliente uno nuevo.';

/// Reads [text] at [_now] and expects the problem [message].
void _refused(String text, String message) => expect(
      () => parseWapuInvoice(text, _now),
      throwsA(isA<WapuInvoiceException>()
          .having((e) => e.message, 'message', message)),
      reason: text,
    );

void main() {
  test('normalizes case, spaces and the lightning: prefix', () {
    expect(
      normalizeDestination('  LIGHTNING:Alice@Example.COM '),
      'alice@example.com',
    );
  });

  test('accepts the lightning:// prefix', () {
    const raw = 'lightning://Alice@Example.com';
    expect(normalizeDestination(raw), 'alice@example.com');
    expect(classifyDestination(raw), DestinationKind.lightningAddress);
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

  group('parseWapuInvoice', () {
    test('reads a mainnet invoice: its sats and when it expires', () {
      final made = _now.subtract(const Duration(minutes: 10));
      final text = _invoice('lnbc25u', made: made, life: 3600);

      final invoice = parseWapuInvoice(text, _now);

      expect(invoice.text, text);
      expect(invoice.sats, 2500);
      expect(invoice.expiresAt, _now.add(const Duration(minutes: 50)));
    });

    test('reads the amount in each unit, down to one sat', () {
      for (final (hrp, sats) in [
        ('lnbc10n', 1),
        ('lnbc2500u', 250000),
        ('lnbc3m', 300000),
        ('lnbc1', 100000000),
      ]) {
        expect(parseWapuInvoice(_invoice(hrp, life: 3600), _now).sats, sats,
            reason: hrp);
      }
    });

    test('an invoice with no expiry lives an hour', () {
      final at = _now.subtract(const Duration(minutes: 44));

      final invoice = parseWapuInvoice(_invoice('lnbc25u', made: at), _now);

      expect(invoice.expiresAt, _now.add(const Duration(minutes: 16)));
      // 46 minutes old, so it has 14 left: the default is an hour, no more.
      _refused(
          _invoice('lnbc25u', made: _now.subtract(const Duration(minutes: 46))),
          _expiresSoon);
    });

    test('needs more than 15 minutes of life left', () {
      expect(kWapuInvoiceMinLife, const Duration(minutes: 15));
      for (final (left, accepted) in [
        (const Duration(minutes: 14), false),
        (const Duration(minutes: 15), false),
        (const Duration(minutes: 15, seconds: 1), true),
        (const Duration(minutes: 16), true),
      ]) {
        final text = _invoice('lnbc25u', life: left.inSeconds);
        if (accepted) {
          expect(parseWapuInvoice(text, _now).sats, 2500, reason: '$left');
        } else {
          _refused(text, _expiresSoon);
        }
      }
    });

    test('refuses one that has expired already', () {
      final made = _now.subtract(const Duration(hours: 2));

      _refused(_invoice('lnbc25u', made: made, life: 3600), _expiresSoon);
    });

    test('refuses an invoice of another network than mainnet', () {
      for (final hrp in ['lntb25u', 'lntbs25u', 'lnbcrt25u']) {
        _refused(_invoice(hrp, life: 3600), _notMainnet);
      }
    });

    test('refuses an invoice with no amount', () {
      _refused(_invoice('lnbc', life: 3600), _noAmount);
      _refused(_invoice('lnbc0u', life: 3600), _noAmount);
    });

    test('refuses an amount that is not a whole number of sats', () {
      // A fraction of a sat, a negative amount, more sats than an int holds.
      for (final hrp in ['lnbc1p', 'lnbc15n', 'lnbc-5u', 'lnbc${'9' * 20}']) {
        _refused(_invoice(hrp, life: 3600), _invalid);
      }
    });

    test('refuses text that is not an invoice', () {
      final text = _invoice('lnbc25u', life: 3600);
      final last = text.endsWith('q') ? 'p' : 'q';

      for (final broken in [
        '${text.substring(0, text.length - 1)}$last', // the checksum fails
        text.substring(0, text.length - 20), // cut short
        'lnbc10u1p3xyz', // too short to hold a checksum
        'lnbc',
      ]) {
        _refused(broken, _invalid);
      }
    });

    test('an invoice scanned as a QR reads like one typed', () {
      final text = _invoice('lnbc25u', life: 3600);
      final raw = ' LIGHTNING:${text.toUpperCase()} ';

      expect(classifyDestination(raw), DestinationKind.invoice);
      expect(normalizeDestination(raw), text);
      expect(parseWapuInvoice(normalizeDestination(raw), _now).sats, 2500);
    });
  });
}
