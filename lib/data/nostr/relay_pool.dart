import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'event.dart';

/// Fetch every event matching [filters] across [relays], returning once each
/// relay has sent its EOSE — or [timeout] elapses, whichever comes first.
///
/// Deliberately **not** a first-relay-wins race like the avatar lookup this
/// replaced. A lagging relay can hold an older version of a replaceable event,
/// and taking the first answer would happily sell last month's price with a
/// perfectly valid signature. Collect from everyone; let the caller pick the
/// newest per address.
///
/// [unreachable] is true only when **not one** relay produced an EVENT or an
/// EOSE. "Nobody answered" and "everybody answered, nothing matched" are
/// different facts and callers must not conflate them: the first means we
/// learned nothing, the second is an authoritative empty result. A relay that
/// replies `CLOSED` settles but does not count as answered — it refused us.
///
/// [complete] is true only when EVERY opened relay reached EOSE. Settling is
/// not completing: a relay that refuses the upgrade, drops the socket, or gets
/// cut off by the [timeout] has told us nothing about what it holds, and the
/// events are then a PARTIAL view rather than the whole set.
/// The difference is not cosmetic. Catalog data is routinely split across
/// relays — one may be the sole holder of the categories or of the kind-5
/// deletions — so a caller that treats a partial read as authoritative will
/// overwrite good data with a fragment, drop every product into "no category",
/// and resurrect products the merchant deleted. A relay that is simply down
/// therefore makes every read incomplete, on purpose: we genuinely do not know
/// what it was holding.
///
/// [idsByRelay] records which relay served which event id, and contains a key
/// ONLY for relays that reached EOSE — i.e. relays whose inventory we actually
/// know. That is what makes a replication pass possible: "relay X is missing
/// event Y" is only a safe claim about a relay that finished answering.
///
/// Never throws: a dead relay just contributes nothing.
Future<
    ({
      List<NostrEvent> events,
      bool unreachable,
      bool complete,
      Map<String, Set<String>> idsByRelay,
    })> fetchEvents(
  List<Map<String, dynamic>> filters, {
  required List<String> relays,
  Duration timeout = const Duration(seconds: 5),
}) async {
  if (relays.isEmpty || filters.isEmpty) {
    return (
      events: <NostrEvent>[],
      unreachable: true,
      complete: false,
      idsByRelay: <String, Set<String>>{},
    );
  }

  // One REQ carrying every filter: NIP-01 sends a single EOSE once all of them
  // are served, so a relay needs exactly one settle signal.
  final subId = 'q${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
  final req = jsonEncode(['REQ', subId, ...filters]);

  final byId = <String, NostrEvent>{};
  final channels = <WebSocketChannel>[];
  final subs = <StreamSubscription<dynamic>>[];
  final opened = <String>[];
  final settled = <String>{}; // guarded: a relay must not settle twice
  final eosed = <String>{}; // reached a real end-of-stored-events
  final seen = <String, Set<String>>{}; // url -> event ids that relay served
  final done = Completer<void>();
  var opening = true;
  var answered = false;
  var timedOut = false;

  void maybeFinish() {
    if (!opening && settled.length >= opened.length && !done.isCompleted) {
      done.complete();
    }
  }

  void settle(String url) {
    if (settled.add(url)) maybeFinish();
  }

  void onMessage(String url, dynamic raw) {
    if (raw is! String) return;
    try {
      final msg = jsonDecode(raw);
      if (msg is! List || msg.isEmpty) return;
      switch (msg[0]) {
        case 'EVENT' when msg.length >= 3:
          answered = true;
          final ev = NostrEvent.fromJson((msg[2] as Map).cast<String, dynamic>());
          final id = ev.id ?? ev.computedId;
          byId[id] = ev;
          (seen[url] ??= <String>{}).add(id);
        case 'EOSE':
          answered = true;
          eosed.add(url);
          settle(url);
        case 'CLOSED':
          settle(url); // refused the subscription; nothing more is coming
      }
    } catch (_) {/* malformed relay frame */}
  }

  for (final url in relays) {
    try {
      final ch = WebSocketChannel.connect(Uri.parse(url));
      channels.add(ch);
      opened.add(url);
      subs.add(ch.stream.listen(
        (raw) => onMessage(url, raw),
        onError: (_) => settle(url),
        onDone: () => settle(url),
        cancelOnError: false,
      ));
      // A refused or non-upgraded connection surfaces on `ready` — NOT on the
      // stream, and not synchronously here. Left unhandled it becomes an
      // unhandled async error AND the relay never settles, so every read waits
      // out the full timeout and comes back a fragment. Observed against
      // relay.damus.io, which answers the handshake without upgrading.
      unawaited(ch.ready.then<void>((_) {
        if (!done.isCompleted) ch.sink.add(req);
      }).catchError((Object e) {
        debugPrint('fetchEvents: $url did not connect: $e');
        settle(url);
      }));
    } catch (e) {
      debugPrint('fetchEvents: relay $url failed: $e');
    }
  }
  opening = false;
  maybeFinish();

  if (opened.isEmpty) {
    return (
      events: <NostrEvent>[],
      unreachable: true,
      complete: false,
      idsByRelay: <String, Set<String>>{},
    );
  }

  final timer = Timer(timeout, () {
    if (done.isCompleted) return;
    // Someone was still streaming. Whatever we hold is a fragment.
    timedOut = true;
    done.complete();
  });
  await done.future;
  timer.cancel();

  for (final ch in channels) {
    try {
      ch.sink.add(jsonEncode(['CLOSE', subId]));
    } catch (_) {/* already gone */}
  }
  for (final s in subs) {
    unawaited(s.cancel());
  }
  for (final ch in channels) {
    try {
      unawaited(ch.sink.close());
    } catch (_) {}
  }

  return (
    events: byId.values.toList(),
    unreachable: !answered,
    // Coverage is not completeness. One relay may be the only one holding the
    // categories or the deletions — observed for real: relay.damus.io carried
    // every kind-30405 and kind-5 for a merchant whose products lived on
    // relay.lacrypta.ar, and its intermittent upgrade failure made the menu
    // alternate between 4 products with categories and 5 products (one of them
    // deleted) with none.
    complete: !timedOut && eosed.length >= opened.length,
    // Only relays that finished answering. A relay that never EOSE'd has an
    // unknown inventory, and "missing" is meaningless against unknown.
    idsByRelay: {for (final u in eosed) u: seen[u] ?? <String>{}},
  );
}

/// Republish [events] to a single [relay] over one connection.
///
/// These are events we FETCHED — already signed by their author. Rebroadcasting
/// a signed event is a plain nostr operation and needs no private key: the
/// signature travels with it and every relay verifies it independently. Nothing
/// here creates or signs anything.
///
/// Sent one at a time, each awaiting its `OK`, rather than blasted: a relay that
/// rate-limits a burst answers with failures (or silence) for events that were
/// perfectly acceptable, and the whole point of this is an honest report.
Future<({String? error, List<RelayPublishResult> results})> publishEvents(
  List<NostrEvent> events,
  String relay, {
  Duration perEvent = const Duration(seconds: 6),
}) async {
  final results = <RelayPublishResult>[];
  if (events.isEmpty) return (error: null, results: results);

  WebSocketChannel? ch;
  StreamSubscription<dynamic>? sub;
  final pending = <String, Completer<RelayPublishResult>>{};

  try {
    ch = WebSocketChannel.connect(Uri.parse(relay));
    sub = ch.stream.listen((raw) {
      if (raw is! String) return;
      try {
        final msg = jsonDecode(raw);
        if (msg is! List || msg.isEmpty || msg[0] != 'OK' || msg.length < 3) {
          return;
        }
        final id = msg[1] as String;
        final ok = msg[2] == true;
        final message = msg.length >= 4 ? '${msg[3]}' : '';
        final c = pending.remove(id);
        if (c != null && !c.isCompleted) {
          c.complete((relay: relay, eventId: id, ok: ok, message: message));
        }
      } catch (_) {/* malformed frame */}
    }, onError: (_) {}, onDone: () {}, cancelOnError: false);

    try {
      await ch.ready.timeout(perEvent);
    } catch (e) {
      // The socket never opened. That is ONE fact about the relay, not a
      // separate failure per event — reporting it per event buries the log in
      // dozens of copies of the same sentence.
      return (error: '$e', results: results);
    }

    for (final e in events) {
      final id = e.id ?? e.computedId;
      final c = Completer<RelayPublishResult>();
      pending[id] = c;
      ch.sink.add(jsonEncode(['EVENT', e.toJson()]));
      results.add(await c.future.timeout(
        perEvent,
        onTimeout: () => (
          relay: relay,
          eventId: id,
          ok: false,
          message: 'sin respuesta del relay',
        ),
      ));
      pending.remove(id);
    }
  } catch (e) {
    return (error: '$e', results: results);
  } finally {
    unawaited(sub?.cancel() ?? Future.value());
    try {
      unawaited(ch?.sink.close() ?? Future.value());
    } catch (_) {}
  }
  return (error: null, results: results);
}

typedef RelayPublishResult = ({
  String relay,
  String eventId,
  bool ok,
  String message,
});

/// Watches a set of Nostr relays for the NIP-57 **zap receipt** (kind 9735) that
/// confirms our invoice was paid, keeping the relay connections open until the
/// receipt arrives or [dispose] is called.
///
/// The receipt is matched by its `bolt11` tag equalling our invoice, so it works
/// even if a relay ignores the `#e` filter hint.
class ZapWatcher {
  ZapWatcher({
    required this.relays,
    required this.zapperPubkey,
    required this.invoice,
    required this.onPaid,
    this.orderId,
  });

  final List<String> relays;
  final String zapperPubkey; // provider's nostrPubkey — author of the receipt
  final String invoice; // our bolt11
  final String? orderId; // the `e` tag placed in the zap request
  final VoidCallback onPaid;

  final List<WebSocketChannel> _channels = [];
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _done = false;

  bool get isActive => _channels.isNotEmpty && !_done;

  void start() {
    if (relays.isEmpty || zapperPubkey.isEmpty || _done) return;
    final subId = 'zap-${invoice.hashCode.toRadixString(16)}';
    final since = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 300;
    final filter = <String, dynamic>{
      'kinds': [9735],
      'authors': [zapperPubkey],
      'since': since,
      if (orderId != null) '#e': [orderId],
    };
    final req = jsonEncode(['REQ', subId, filter]);
    for (final url in relays) {
      try {
        final ch = WebSocketChannel.connect(Uri.parse(url));
        _channels.add(ch);
        _subs.add(ch.stream.listen(
          _onMessage,
          onError: (_) {},
          onDone: () {},
          cancelOnError: false,
        ));
        // Same trap as `fetchEvents`: a connection that is refused or not
        // upgraded fails on `ready`, not here and not on the stream. Writing to
        // that sink raised an unhandled exception out of the payment screen on
        // every charge, once per dead relay.
        unawaited(ch.ready.then<void>((_) {
          if (!_done) ch.sink.add(req);
        }).catchError((Object e) {
          debugPrint('ZapWatcher: $url did not connect: $e');
        }));
      } catch (e) {
        debugPrint('ZapWatcher: relay $url failed: $e');
      }
    }
  }

  void _onMessage(dynamic raw) {
    if (_done || raw is! String) return;
    try {
      final msg = jsonDecode(raw);
      if (msg is! List || msg.length < 3 || msg[0] != 'EVENT') return;
      final ev = (msg[2] as Map).cast<String, dynamic>();
      if (ev['kind'] != 9735) return;
      final tags = ev['tags'] as List?;
      if (tags == null) return;
      for (final t in tags) {
        if (t is List &&
            t.length >= 2 &&
            t[0] == 'bolt11' &&
            t[1].toString().toLowerCase() == invoice.toLowerCase()) {
          _fire();
          return;
        }
      }
    } catch (_) {/* ignore malformed relay frames */}
  }

  void _fire() {
    if (_done) return;
    _done = true;
    onPaid();
    dispose();
  }

  void dispose() {
    _done = true;
    for (final s in _subs) {
      s.cancel();
    }
    for (final ch in _channels) {
      try {
        ch.sink.close();
      } catch (_) {}
    }
    _subs.clear();
    _channels.clear();
  }
}
