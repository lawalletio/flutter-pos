import 'package:flutter/foundation.dart';

import 'catalog.dart';
import 'event.dart';
import 'relay_list.dart';
import 'relay_pool.dart';

/// One line of the sync log.
@immutable
class SyncLogEntry {
  final DateTime at;
  final String relay;
  final String message;
  final bool ok;

  /// Section headers and totals rather than a single event's outcome.
  final bool isNote;

  /// Refused on policy grounds — shown muted, not as an error.
  final bool refused;

  const SyncLogEntry({
    required this.at,
    required this.relay,
    required this.message,
    required this.ok,
    this.isNote = false,
    this.refused = false,
  });
}

enum SyncPhase { idle, running, done, failed }

/// What a relay's `OK` reply actually meant.
enum PublishOutcome {
  /// Accepted, or the relay already had it.
  accepted,

  /// A deliberate policy refusal — it will say the same thing forever.
  refused,

  /// Something that might work next time (rate limit, transient error).
  transient,
}

/// NIP-01 gives `OK` messages a machine-readable prefix. Reading it is the
/// difference between "retry later" and "never ask again": most of what a
/// backfill hits is `invalid: created_at too early`, because relays refuse old
/// events to stop exactly this kind of bulk replay. Retrying those on every
/// merchant switch is pure noise in the log and pure load on the relay.
PublishOutcome classifyOk(bool ok, String message) {
  final m = message.toLowerCase().trim();
  // Plenty of relays answer `true` here, some `false`; either way they have it.
  if (m.startsWith('duplicate:')) return PublishOutcome.accepted;
  if (ok) return PublishOutcome.accepted;
  for (final prefix in const [
    'invalid:',
    'blocked:',
    'restricted:',
    'auth-required:',
    'pow:',
  ]) {
    if (m.startsWith(prefix)) return PublishOutcome.refused;
  }
  return PublishOutcome.transient;
}

@immutable
class SyncReport {
  final SyncPhase phase;
  final String? address;

  /// Relays in the working set: the merchant's own plus the till's.
  final List<RelayEntry> relays;

  final int relaysDone;
  final int published;
  final int failed;

  /// Refused on purpose by the relay (old timestamp, spam policy, auth). Not an
  /// error to chase — surfaced separately so a wall of policy refusals does not
  /// read as a broken sync.
  final int refused;

  /// Relays that were already holding everything.
  final int alreadyInSync;

  final List<SyncLogEntry> log;
  final DateTime? finishedAt;

  const SyncReport({
    this.phase = SyncPhase.idle,
    this.address,
    this.relays = const [],
    this.relaysDone = 0,
    this.published = 0,
    this.failed = 0,
    this.refused = 0,
    this.alreadyInSync = 0,
    this.log = const [],
    this.finishedAt,
  });

  bool get isRunning => phase == SyncPhase.running;
  int get relayCount => relays.length;

  SyncReport copyWith({
    SyncPhase? phase,
    String? address,
    List<RelayEntry>? relays,
    int? relaysDone,
    int? published,
    int? failed,
    int? refused,
    int? alreadyInSync,
    List<SyncLogEntry>? log,
    DateTime? finishedAt,
  }) =>
      SyncReport(
        phase: phase ?? this.phase,
        address: address ?? this.address,
        relays: relays ?? this.relays,
        relaysDone: relaysDone ?? this.relaysDone,
        published: published ?? this.published,
        failed: failed ?? this.failed,
        refused: refused ?? this.refused,
        alreadyInSync: alreadyInSync ?? this.alreadyInSync,
        log: log ?? this.log,
        finishedAt: finishedAt ?? this.finishedAt,
      );
}

/// Replicates a merchant's catalog across every relay in the working set.
///
/// The problem it solves is real and was diagnosed on live data: the categories
/// (kind 30405) and the deletions (kind 5) for one merchant existed ONLY on
/// relay.damus.io while their products sat on relay.lacrypta.ar. Whenever damus
/// failed its websocket upgrade the menu lost every category and resurrected a
/// deleted product. Making each relay hold the whole set removes that
/// dependency on any single relay staying up.
///
/// Nothing here signs anything. Every event was fetched already signed by the
/// merchant; republishing carries the signature along and each relay verifies
/// it independently.
class RelaySyncService {
  final ValueNotifier<SyncReport> notifier =
      ValueNotifier<SyncReport>(const SyncReport());

  SyncReport get report => notifier.value;

  Future<void>? _inFlight;

  /// `relay|eventId` pairs a relay refused on policy grounds. Skipped on later
  /// passes: asking again cannot change a "created_at too early".
  final Set<String> _refused = <String>{};

  /// Discover the merchant's NIP-65 relays and merge them with the till's.
  ///
  /// Chicken-and-egg: finding a relay list needs relays. Bootstrap from the
  /// till's own set plus any NIP-05 hint, which is also where the profile
  /// indexers live.
  Future<List<RelayEntry>> discoverRelays({
    required String pubkey,
    required List<String> hints,
    required List<String> defaults,
  }) async {
    final bootstrap = <String>{
      ...hints,
      ...defaults,
      // The de-facto kind-10002 indexer; cheap to ask and often the only
      // place a relay list is stored.
      'wss://purplepag.es',
    }.toList();

    var merchant = const <RelayEntry>[];
    try {
      final fetched = await fetchEvents(
        [
          {
            'kinds': [kindRelayList],
            'authors': [pubkey],
            'limit': 1,
          }
        ],
        relays: bootstrap,
        timeout: const Duration(seconds: 6),
      );
      NostrEvent? newest;
      for (final e in fetched.events) {
        if (e.kind != kindRelayList || e.pubkey != pubkey) continue;
        if (newest == null || e.createdAt > newest.createdAt) newest = e;
      }
      if (newest != null) merchant = parseRelayListEvent(newest);
    } catch (e) {
      debugPrint('RelaySync: relay list lookup failed: $e');
    }

    return aggregateRelays(
      merchant: merchant,
      hints: hints,
      defaults: defaults,
    );
  }

  /// Record that replication could not safely run this time.
  ///
  /// The gate is not cosmetic: the live set is computed by applying the kind-5
  /// deletions, so if a relay we could not reach was the only holder of one,
  /// the "live" set still contains a product the merchant deleted — and
  /// republishing it would resurrect it on every relay that had correctly
  /// dropped it. Skipping is right; hiding the fact is not, which is why this
  /// still populates the report so the icon appears and explains itself.
  void skipped({
    required String address,
    required List<RelayEntry> relays,
    required String reason,
  }) {
    if (_inFlight != null) return; // a real pass is running; do not stomp it
    notifier.value = SyncReport(
      phase: SyncPhase.done,
      address: address,
      relays: relays,
      log: [
        SyncLogEntry(
          at: DateTime.now(),
          relay: '',
          ok: false,
          isNote: true,
          refused: true, // informational, not an alarm
          message: 'Replicación omitida: $reason',
        ),
      ],
      finishedAt: DateTime.now(),
    );
  }

  /// Publish to each relay whatever it is missing.
  ///
  /// [idsByRelay] must only contain relays that finished answering — a relay
  /// with an unknown inventory cannot be said to be "missing" anything, and
  /// blasting the full catalog at it on every menu open would be abuse.
  Future<void> sync({
    required String address,
    required List<RelayEntry> relays,
    required List<NostrEvent> events,
    required Map<String, Set<String>> idsByRelay,
  }) {
    if (_inFlight != null) return _inFlight!;
    return _inFlight =
        _run(address, relays, events, idsByRelay).whenComplete(() {
      _inFlight = null;
    });
  }

  Future<void> _run(
    String address,
    List<RelayEntry> relays,
    List<NostrEvent> events,
    Map<String, Set<String>> idsByRelay,
  ) async {
    final log = <SyncLogEntry>[];
    void note(String relay, String message, {bool ok = true}) {
      log.add(SyncLogEntry(
          at: DateTime.now(),
          relay: relay,
          message: message,
          ok: ok,
          isNote: true));
    }

    notifier.value = SyncReport(
      phase: SyncPhase.running,
      address: address,
      relays: relays,
      log: log,
    );

    if (events.isEmpty) {
      note('', 'No hay eventos para replicar.');
      notifier.value = notifier.value.copyWith(
        phase: SyncPhase.done,
        log: List.of(log),
        finishedAt: DateTime.now(),
      );
      return;
    }

    note('', '${events.length} eventos · ${relays.length} relays');

    var published = 0;
    var failed = 0;
    var refusedCount = 0;
    var inSync = 0;
    var done = 0;
    var unreachable = 0; // relays we could not talk to at all

    for (final entry in relays) {
      final known = idsByRelay[entry.url];
      if (!entry.write) {
        note(entry.url, 'Solo lectura, se omite.');
        done++;
      } else if (known == null) {
        // We never heard a full answer from it, so we do not know what it has.
        unreachable++;
        note(entry.url, 'No respondió; no se puede saber qué le falta.',
            ok: false);
        done++;
      } else {
        final missing = <NostrEvent>[];
        var skipped = 0;
        for (final e in events) {
          final id = e.id ?? e.computedId;
          if (known.contains(id)) continue;
          // Already told us no, on policy grounds. Asking again is noise.
          if (_refused.contains('${entry.url}|$id')) {
            skipped++;
            continue;
          }
          missing.add(e);
        }
        if (missing.isEmpty) {
          inSync++;
          note(
            entry.url,
            skipped == 0
                ? 'Ya tenía los ${events.length} eventos.'
                : 'Al día ($skipped rechazados previamente, no se reintentan).',
          );
          done++;
        } else {
          note(entry.url, 'Faltan ${missing.length} eventos, publicando…');
          final outcome = await publishEvents(missing, entry.url);
          if (outcome.error != null) {
            // One fact about the relay, logged once — not the same sentence
            // repeated for every event we never got to send.
            failed++;
            unreachable++;
            note(entry.url, 'No se pudo conectar: ${outcome.error}', ok: false);
          }
          for (final r in outcome.results) {
            final kind = _kindOf(events, r.eventId);
            final outcomeKind = classifyOk(r.ok, r.message);
            switch (outcomeKind) {
              case PublishOutcome.accepted:
                published++;
              case PublishOutcome.refused:
                refusedCount++;
                _refused.add('${entry.url}|${r.eventId}');
              case PublishOutcome.transient:
                failed++;
            }
            log.add(SyncLogEntry(
              at: DateTime.now(),
              relay: entry.url,
              // A policy refusal is not an error state: it is the relay working
              // as designed, so it must not paint the log red or light the
              // error badge in the app bar.
              ok: outcomeKind != PublishOutcome.transient,
              refused: outcomeKind == PublishOutcome.refused,
              message: switch (outcomeKind) {
                PublishOutcome.accepted =>
                  'Publicado $kind ${_short(r.eventId)}',
                PublishOutcome.refused =>
                  'Rechazado $kind ${_short(r.eventId)}: ${r.message}',
                PublishOutcome.transient =>
                  'Falló $kind ${_short(r.eventId)}: ${r.message}',
              },
            ));
          }
          done++;
        }
      }

      notifier.value = notifier.value.copyWith(
        relaysDone: done,
        published: published,
        failed: failed,
        refused: refusedCount,
        alreadyInSync: inSync,
        log: List.of(log),
      );
    }

    note(
      '',
      'Listo: $published publicados, $refusedCount rechazados por política, '
      '$failed fallidos, $inSync relays al día.',
    );
    notifier.value = notifier.value.copyWith(
      // Failed only when NOT ONE relay could be reached. One dead relay out of
      // seven is normal — relay.damus.io has been refusing the websocket
      // upgrade for days — and painting the badge red for it permanently would
      // train the operator to ignore the badge, which is the one thing it must
      // not do.
      phase: unreachable >= relays.length ? SyncPhase.failed : SyncPhase.done,
      relaysDone: done,
      published: published,
      failed: failed,
      refused: refusedCount,
      alreadyInSync: inSync,
      log: List.of(log),
      finishedAt: DateTime.now(),
    );
  }

  String _kindOf(List<NostrEvent> events, String id) {
    for (final e in events) {
      if ((e.id ?? e.computedId) == id) {
        switch (e.kind) {
          case kindProduct:
            return 'producto';
          case kindCategory:
            return 'categoría';
          case kindDeletion:
            return 'borrado';
          default:
            return 'kind ${e.kind}';
        }
      }
    }
    return 'evento';
  }

  String _short(String id) => id.length <= 8 ? id : id.substring(0, 8);
}

/// App-wide relay replication singleton.
final RelaySyncService relaySync = RelaySyncService();
