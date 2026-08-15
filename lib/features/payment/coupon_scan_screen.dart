import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  /// The camera keeps running behind the manual-entry dialog. Without this a
  /// coupon drifting into frame pops the route out from under the dialog and
  /// applies a code nobody typed.
  bool _typing = false;

  final _manual = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    _manual.dispose();
    super.dispose();
  }

  /// Type or paste the code, for a coupon that arrived as text — a screenshot
  /// that will not focus, a code read out over the phone, a camera that is
  /// having a bad day.
  Future<void> _enterManually() async {
    setState(() => _typing = true);
    final nonce = await showDialog<String>(
      context: context,
      builder: (ctx) => _ManualCouponDialog(controller: _manual),
    );
    if (!mounted) return;
    setState(() => _typing = false);
    if (nonce != null) {
      _done = true;
      Navigator.of(context).pop(nonce);
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done || _typing) return;
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
              bottom: 32,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
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
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: _enterManually,
                    icon: const Icon(Icons.keyboard, size: 20),
                    label: Text(context.tr('Ingresar el código')),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}


/// Type or paste a coupon code. Pops the nonce, or null.
class _ManualCouponDialog extends StatefulWidget {
  const _ManualCouponDialog({required this.controller});
  final TextEditingController controller;

  @override
  State<_ManualCouponDialog> createState() => _ManualCouponDialogState();
}

class _ManualCouponDialogState extends State<_ManualCouponDialog> {
  /// The nonce the current text holds, or null. Accepts a pasted link too, so
  /// whatever the customer copied off their phone works without editing it.
  String? get _nonce => nonceFromScan(widget.controller.text);

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || !mounted) return;
    widget.controller.text = text.trim();
    setState(() {});
  }

  void _submit() {
    final nonce = _nonce;
    if (nonce != null) Navigator.of(context).pop(nonce);
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.controller.text.trim();
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(context.tr('Código del cupón')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: widget.controller,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              hintText: context.tr('Pegá o escribí el código'),
              suffixIcon: IconButton(
                tooltip: context.tr('Pegar'),
                icon: const Icon(Icons.content_paste),
                onPressed: _paste,
              ),
            ),
          ),
          // Only once there is something to be wrong about: an error under an
          // empty field reads as a broken screen.
          if (text.isNotEmpty && _nonce == null) ...[
            const SizedBox(height: 8),
            Text(context.tr('Ese código no es un cupón'),
                style: const TextStyle(color: AppColors.error, fontSize: 13)),
          ],
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.tr('Cancelar'))),
        FilledButton(
          onPressed: _nonce == null ? null : _submit,
          child: Text(context.tr('Aplicar')),
        ),
      ],
    );
  }
}
