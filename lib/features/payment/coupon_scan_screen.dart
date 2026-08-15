import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../domain/coupon/coupon.dart';

/// Scan a coupon QR. Pops the nonce, or null if the cashier backed out.
class CouponScanScreen extends StatefulWidget {
  const CouponScanScreen({super.key});

  @override
  State<CouponScanScreen> createState() => _CouponScanScreenState();
}

/// The nonce carried by a scanned QR, or null.
///
/// Coupons travel two ways: bare, and as a link the customer opened on their
/// phone (`https://…/?coupon=<nonce>`). Both are the same credential.
String? nonceFromScan(String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return null;
  if (isValidNonce(value)) return value;
  final fromQuery = Uri.tryParse(value)?.queryParameters['coupon'];
  return isValidNonce(fromQuery) ? fromQuery : null;
}

class _CouponScanScreenState extends State<CouponScanScreen> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );

  /// A QR is detected many times a second; without this the screen pops once
  /// per frame and the coupon is checked repeatedly.
  bool _done = false;
  bool _rejected = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final nonce = nonceFromScan(b.rawValue);
      if (nonce != null) {
        _done = true;
        Navigator.of(context).pop(nonce);
        return;
      }
    }
    // Something was read and it was not a coupon. Say so instead of leaving the
    // cashier holding a QR at a camera that looks broken.
    if (!_rejected && capture.barcodes.isNotEmpty) {
      setState(() => _rejected = true);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: PosAppBar(
            title: context.tr('Escanear cupón'), showSettings: false, showSync: false),
        body: Stack(
          fit: StackFit.expand,
          children: [
            MobileScanner(controller: _controller, onDetect: _onDetect),
            Center(
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.primary, width: 3),
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
            Positioned(
              left: 20,
              right: 20,
              bottom: 40,
              child: Text(
                _rejected
                    ? context.tr('Ese QR no es un cupón')
                    : context.tr('Apuntá al QR del cupón'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _rejected ? AppColors.error : Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  shadows: const [Shadow(blurRadius: 8)],
                ),
              ),
            ),
          ],
        ),
      );
}
