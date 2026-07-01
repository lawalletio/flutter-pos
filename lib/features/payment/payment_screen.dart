import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../domain/config/currencies.dart';
import '../../domain/config/formatter.dart';

/// Payment — invoice QR + waiting/paid states. UI-only: a demo button toggles the
/// "paid" state (the real dual-detection engine wires in M3).
class PaymentScreen extends StatefulWidget {
  final int amountSats;
  final bool initiallyPaid;
  const PaymentScreen({super.key, required this.amountSats, this.initiallyPaid = false});
  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  late bool _paid = widget.initiallyPaid;

  // A representative bolt11 string just to render the QR in preview.
  String get _invoice =>
      'lnbc${widget.amountSats}n1pjmockinvoice0lawalletposdemo${widget.amountSats}';

  @override
  Widget build(BuildContext context) {
    final sats = formatToPreference(Currency.sat, widget.amountSats);
    return Scaffold(
      appBar: PosAppBar(title: _paid ? null : 'Cobrar', showSettings: false),
      body: PosBody(
        child: _paid ? _paidView(context, sats) : _waitingView(context, sats),
      ),
    );
  }

  Widget _waitingView(BuildContext context, String sats) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 10),
            Text('Esperando el pago…', style: TextStyle(color: AppColors.muted)),
          ],
        ),
        const SizedBox(height: 18),
        Text('$sats sats',
            style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('≈ ${formatToPreference(Currency.ars, widget.amountSats * 0.7)} ARS',
            style: const TextStyle(color: AppColors.muted)),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: Colors.white, borderRadius: BorderRadius.circular(16)),
          child: QrImageView(
            data: _invoice,
            version: QrVersions.auto,
            size: 240,
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.nfc),
                label: const Text('Solicitar NFC'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton(
                onPressed: () => context.pop(),
                child: const Text('Cancelar'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Demo-only: simulate a detected payment.
        TextButton(
          onPressed: () => setState(() => _paid = true),
          child: const Text('▶ Simular pago recibido (demo)'),
        ),
      ],
    );
  }

  Widget _paidView(BuildContext context, String sats) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration:
              const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
          child: const Icon(Icons.check, size: 56, color: Colors.black),
        ),
        const SizedBox(height: 20),
        const Text('Pago acreditado',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text('$sats sats', style: const TextStyle(color: AppColors.muted, fontSize: 18)),
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => context.go('/hub'),
            child: const Text('Volver'),
          ),
        ),
      ],
    );
  }
}
