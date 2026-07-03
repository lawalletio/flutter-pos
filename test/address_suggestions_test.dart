import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/features/home/home_screen.dart';

void main() {
  group('buildAddressSuggestions', () {
    test('username only → user@provider combos (LaWallet ecosystem first)', () {
      final s = buildAddressSuggestions('pepe', const []);
      expect(s.first, 'pepe@lawallet.io');
      expect(s[1], 'pepe@lacrypta.ar');
      expect(s, contains('pepe@walletofsatoshi.com'));
      expect(s, contains('pepe@blink.sv'));
      expect(s, contains('pepe@strike.me'));
      expect(s, contains('pepe@getalby.com'));
    });

    test('caps at 7 suggestions', () {
      final history = List.generate(10, (i) => 'pepe$i@lawallet.io');
      final s = buildAddressSuggestions('pepe', history);
      expect(s.length, 7);
    });

    test('domain fragment completes against matching providers only', () {
      expect(buildAddressSuggestions('pepe@bl', const []), ['pepe@blink.sv']);
      expect(buildAddressSuggestions('pepe@l', const []),
          ['pepe@lawallet.io', 'pepe@lacrypta.ar']);
      // Empty domain part → all providers.
      expect(buildAddressSuggestions('pepe@', const []).length, 6);
    });

    test('history matches rank ahead of generated combos', () {
      final s = buildAddressSuggestions('pepe', const ['pepe@lacrypta.ar']);
      expect(s.first, 'pepe@lacrypta.ar'); // from history, deduped
      expect(s, contains('pepe@lawallet.io'));
      // No duplicate of the history entry.
      expect(s.where((e) => e == 'pepe@lacrypta.ar').length, 1);
    });

    test('never suggests the exact text already typed', () {
      final s = buildAddressSuggestions('pepe@lawallet.io', const []);
      expect(s, isNot(contains('pepe@lawallet.io')));
    });

    test('empty input returns recent history', () {
      final s = buildAddressSuggestions('', const ['a@lawallet.io', 'b@blink.sv']);
      expect(s, ['a@lawallet.io', 'b@blink.sv']);
    });

    test('is case-insensitive on the typed username', () {
      expect(buildAddressSuggestions('PEPE', const []).first, 'pepe@lawallet.io');
    });
  });

  group('isValidLightningAddress', () {
    test('accepts a well-formed user@domain.tld', () {
      expect(isValidLightningAddress('pepe@lawallet.io'), isTrue);
      expect(isValidLightningAddress('a.b+c@sub.example.co'), isTrue);
      expect(isValidLightningAddress('  pepe@blink.sv  '), isTrue); // trimmed
    });

    test('rejects malformed input', () {
      expect(isValidLightningAddress('pepe'), isFalse); // no @
      expect(isValidLightningAddress('pepe@lawallet'), isFalse); // no TLD dot
      expect(isValidLightningAddress('pepe@.io'), isFalse); // empty domain
      expect(isValidLightningAddress('@lawallet.io'), isFalse); // empty user
      expect(isValidLightningAddress('pe pe@lawallet.io'), isFalse); // space
      expect(isValidLightningAddress(''), isFalse);
    });
  });
}
