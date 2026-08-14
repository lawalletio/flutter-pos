import 'package:flutter/foundation.dart';

import '../../domain/config/settings_state.dart';
import 'event.dart';

/// NIP-65 relay list metadata (kind 10002).
const int kindRelayList = 10002;

/// Where a relay in the working set came from — shown in the sync log so an
/// operator can tell "the merchant publishes here" from "the till always asks
/// here".
enum RelaySource { merchant, pos }

@immutable
class RelayEntry {
  final String url;
  final bool read;
  final bool write;
  final RelaySource source;

  const RelayEntry({
    required this.url,
    required this.read,
    required this.write,
    required this.source,
  });

  RelayEntry mergedWith(RelayEntry other) => RelayEntry(
        url: url,
        read: read || other.read,
        write: write || other.write,
        // The merchant's own declaration is the more meaningful label.
        source: source == RelaySource.merchant ? source : other.source,
      );
}

/// Parse a kind-10002 event into relay entries.
///
/// Tag shape is `["r", "<url>"]` with an optional third element of "read" or
/// "write". An OMITTED marker means BOTH — the single most commonly
/// mis-implemented part of NIP-65, so it is handled explicitly here.
List<RelayEntry> parseRelayListEvent(NostrEvent e) {
  if (e.kind != kindRelayList) return const [];

  final out = <RelayEntry>[];
  final seen = <String>{};
  for (final tag in e.tags) {
    if (tag.isEmpty || tag[0] != 'r' || tag.length < 2) continue;
    final url = normalizeRelay(tag[1]);
    if (url == null || !seen.add(url)) continue;

    final marker = tag.length >= 3 ? tag[2].trim().toLowerCase() : '';
    out.add(RelayEntry(
      url: url,
      read: marker != 'write', // no marker at all means read AND write
      write: marker != 'read',
      source: RelaySource.merchant,
    ));
  }
  return out;
}

/// Merge the merchant's declared relays with the till's own list.
///
/// Deduplicated by NORMALISED url, so `relay.foo.ar`, `wss://relay.foo.ar` and
/// `wss://relay.foo.ar/` collapse to one entry. Order is stable and meaningful:
/// the merchant's own relays first (they are where their catalog actually
/// lives), then the till's defaults.
List<RelayEntry> aggregateRelays({
  Iterable<RelayEntry> merchant = const [],
  Iterable<String> hints = const [],
  Iterable<String> defaults = const [],
}) {
  final byUrl = <String, RelayEntry>{};

  void add(RelayEntry entry) {
    final existing = byUrl[entry.url];
    byUrl[entry.url] = existing == null ? entry : existing.mergedWith(entry);
  }

  for (final e in merchant) {
    add(e);
  }
  // NIP-05 `relays` hints carry no read/write markers; treat them as both.
  for (final raw in hints) {
    final url = normalizeRelay(raw);
    if (url != null) {
      add(RelayEntry(
          url: url, read: true, write: true, source: RelaySource.merchant));
    }
  }
  for (final raw in defaults) {
    final url = normalizeRelay(raw);
    if (url != null) {
      add(RelayEntry(
          url: url, read: true, write: true, source: RelaySource.pos));
    }
  }
  return byUrl.values.toList();
}

List<String> readUrls(Iterable<RelayEntry> entries) =>
    [for (final e in entries) if (e.read) e.url];

List<String> writeUrls(Iterable<RelayEntry> entries) =>
    [for (final e in entries) if (e.write) e.url];
