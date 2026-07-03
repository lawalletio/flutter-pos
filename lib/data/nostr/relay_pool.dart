import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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
        ch.sink.add(req);
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
