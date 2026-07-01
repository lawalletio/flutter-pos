import 'package:flutter/services.dart';

class NfcException implements Exception {
  final String message;
  final String? code;
  NfcException(this.message, {this.code});
  @override
  String toString() => message;
}

/// Reads NFC tags via the native NfcAdapter reader mode (see MainActivity.kt).
class NfcChannel {
  static const MethodChannel _ch = MethodChannel('pos/nfc');

  static Future<bool> isAvailable() async {
    try {
      return await _ch.invokeMethod<bool>('isAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Waits for a tag tap and returns its NDEF URL (e.g. `lnurlw://…`).
  static Future<String> read() async {
    try {
      final url = await _ch.invokeMethod<String>('read');
      if (url == null || url.isEmpty) throw NfcException('Tarjeta vacía');
      return url;
    } on MissingPluginException {
      throw NfcException('NFC no disponible en este dispositivo',
          code: 'NFC_UNAVAILABLE');
    } on PlatformException catch (e) {
      throw NfcException(e.message ?? 'Error de NFC', code: e.code);
    }
  }

  static Future<void> cancel() async {
    try {
      await _ch.invokeMethod('cancel');
    } catch (_) {}
  }
}
