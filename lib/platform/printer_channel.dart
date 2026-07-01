import 'package:flutter/services.dart';

/// Result of a print operation (ZCS SdkResult code + optional error).
class PrintResult {
  final int code;
  final String? error;
  const PrintResult(this.code, {this.error});

  bool get ok => error == null && code == 0; // SdkResult.SDK_OK == 0

  String get message {
    if (error != null) return error!;
    switch (code) {
      case 0:
        return 'Impreso correctamente';
      case -1403:
        return 'Sin papel';
      case -1405:
        return 'Impresora sobrecalentada';
      case -1404:
        return 'Fallo de impresora';
      case -100:
        return 'Impresora no disponible';
      default:
        return 'Error de impresión (código $code)';
    }
  }
}

/// Talks to the native ZCS SmartPos printer (see MainActivity.kt).
class PrinterChannel {
  static const MethodChannel _ch = MethodChannel('pos/printer');

  static Future<bool> isAvailable() async {
    try {
      return await _ch.invokeMethod<bool>('isAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<PrintResult> testPrint() => _invoke('testPrint');

  static Future<PrintResult> printOrder(Map<String, dynamic> order) =>
      _invoke('print', order);

  static Future<PrintResult> _invoke(String method, [dynamic args]) async {
    try {
      final code = await _ch.invokeMethod<int>(method, args) ?? -1;
      return PrintResult(code);
    } on MissingPluginException {
      return const PrintResult(-1,
          error: 'Impresora no disponible en este dispositivo');
    } on PlatformException catch (e) {
      return PrintResult(-1, error: e.message ?? 'Error de impresión');
    }
  }
}
