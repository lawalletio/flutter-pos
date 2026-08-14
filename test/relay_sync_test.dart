import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/data/nostr/relay_sync_service.dart';

/// How a relay's `OK` reply is read.
///
/// This is the difference between "retry later" and "never ask again". A
/// backfill mostly hits `invalid: created_at too early` — relays refuse old
/// events precisely to stop bulk replay — and retrying those on every merchant
/// switch floods the log and hammers the relay for nothing.
void main() {
  group('classifyOk', () {
    test('policy refusals are permanent, not failures to retry', () {
      // Both observed verbatim against live relays.
      expect(classifyOk(false, 'invalid: created_at too early'),
          PublishOutcome.refused);
      expect(classifyOk(false, 'blocked: spam not permitted'),
          PublishOutcome.refused);
      expect(classifyOk(false, 'restricted: not on the whitelist'),
          PublishOutcome.refused);
      expect(classifyOk(false, 'auth-required: we only accept from authed'),
          PublishOutcome.refused);
      expect(classifyOk(false, 'pow: difficulty 28 required'),
          PublishOutcome.refused);
    });

    test('a duplicate is a success — the relay already has it', () {
      // Relays disagree on the ok flag for duplicates; both mean "stored".
      expect(classifyOk(true, 'duplicate: have this event'),
          PublishOutcome.accepted);
      expect(classifyOk(false, 'duplicate: have this event'),
          PublishOutcome.accepted);
    });

    test('plain acceptance', () {
      expect(classifyOk(true, ''), PublishOutcome.accepted);
    });

    test('everything else is worth another go', () {
      expect(classifyOk(false, 'rate-limited: slow down'),
          PublishOutcome.transient);
      expect(classifyOk(false, 'error: could not connect to the database'),
          PublishOutcome.transient);
      expect(classifyOk(false, 'sin respuesta del relay'),
          PublishOutcome.transient);
    });

    test('prefix matching is case-insensitive and ignores padding', () {
      expect(classifyOk(false, '  INVALID: created_at too early '),
          PublishOutcome.refused);
    });
  });
}
