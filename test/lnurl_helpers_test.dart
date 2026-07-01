import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/data/lnurl/lnurl_helpers.dart';

void main() {
  group('detectTransferType', () {
    test('classifies lud16 / lnurl / invoice', () {
      expect(detectTransferType('user@lawallet.ar'), TransferType.lud16);
      expect(detectTransferType('LNURL1DP68...'), TransferType.lnurl);
      expect(detectTransferType('lnbc10n1p...'), TransferType.invoice);
      expect(detectTransferType('nonsense'), isNull);
    });
  });

  group('removeLightningStandard', () {
    test('strips lightning:// and lightning: prefixes', () {
      expect(removeLightningStandard('lightning://user@d.com'), 'user@d.com');
      expect(removeLightningStandard('lightning:user@d.com'), 'user@d.com');
      expect(removeLightningStandard('user@d.com'), 'user@d.com');
    });
  });

  group('extractEmailParts', () {
    test('splits username and domain', () {
      final p = extractEmailParts('barra@lacrypta.ar');
      expect(p.username, 'barra');
      expect(p.domain, 'lacrypta.ar');
    });
    test('returns nulls for invalid', () {
      final p = extractEmailParts('nope');
      expect(p.username, isNull);
      expect(p.domain, isNull);
    });
  });

  group('lud16ToUrl / nip05ToUrl', () {
    test('builds well-known URLs', () {
      expect(lud16ToUrl('barra@lacrypta.ar'),
          'https://lacrypta.ar/.well-known/lnurlp/barra');
      expect(nip05ToUrl('barra@lacrypta.ar'),
          'https://lacrypta.ar/.well-known/nostr.json?name=barra');
    });
    test('lowercases and trims', () {
      expect(lud16ToUrl('  Barra@LaCrypta.ar '),
          'https://lacrypta.ar/.well-known/lnurlp/barra');
    });
    test('throws on invalid address', () {
      expect(() => lud16ToUrl('nope'), throwsArgumentError);
    });
  });
}
