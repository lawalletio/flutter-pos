import 'package:flutter/services.dart';

class NfcException implements Exception {
  final String message;
  final String? code;
  NfcException(this.message, {this.code});
  @override
  String toString() => message;
}

/// NFC via a persistent native reader session (see MainActivity.kt). While the
/// session is active, reader mode stays exclusively on (so the system Tag viewer
/// never intercepts a tap) and each tag's NDEF URL is streamed via [tags].
class NfcChannel {
  static const MethodChannel _ch = MethodChannel('pos/nfc');
  static const EventChannel _events = EventChannel('pos/nfc/tags');

  static Future<bool> isAvailable() async {
    try {
      return await _ch.invokeMethod<bool>('isAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Start the reader session; returns true if reader mode is active.
  static Future<bool> startSession() async {
    try {
      return await _ch.invokeMethod<bool>('startSession') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> stopSession() async {
    try {
      await _ch.invokeMethod('stopSession');
    } catch (_) {}
  }

  /// Stream of tag NDEF URLs (e.g. `lnurlw://…`).
  static Stream<String> tags() => _events
      .receiveBroadcastStream()
      .where((e) => e != null)
      .map((e) => e.toString());
}
