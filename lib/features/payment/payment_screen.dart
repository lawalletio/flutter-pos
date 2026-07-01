import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../domain/config/currencies.dart';
import '../../domain/config/formatter.dart';
import '../../domain/config/settings_state.dart';

/// Payment — invoice QR + waiting / paid / checking / no-amount / added-to-tab
/// states. UI-only: the "Simular pago" and "Check event" demo buttons stand in
/// for the real dual-detection engine (M3).
class PaymentScreen extends StatefulWidget {
  final int amountSats;
  final bool initiallyPaid;
  final String? back;
  const PaymentScreen({
    super.key,
    required this.amountSats,
    this.initiallyPaid = false,
    this.back,
  });
  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

enum _View { waiting, paid, checking, addedToTab }

class _PaymentScreenState extends State<PaymentScreen> {
  static const _arsPerBtc = 70000000.0;
  late _View _view = widget.initiallyPaid ? _View.paid : _View.waiting;
  String? _tabName;

  String get _invoice =>
      'lnbc${widget.amountSats}n1pjmockinvoice0lawalletposdemo${widget.amountSats}';

  String get _satsStr => formatToPreference(Currency.sat, widget.amountSats);
  String get _arsStr => formatToPreference(
      Currency.ars, widget.amountSats / 100000000 * _arsPerBtc);

  void _goBack() {
    if (widget.back != null && widget.back!.isNotEmpty) {
      context.go(widget.back!);
    } else {
      context.go('/hub');
    }
  }

  @override
  Widget build(BuildContext context) {
    // No amount → cannot generate an invoice (webapp shows an explicit message).
    if (widget.amountSats <= 0 && _view == _View.waiting) {
      return _scaffold(_noAmountView());
    }
    switch (_view) {
      case _View.paid:
        return _scaffold(_paidView(), title: null);
      case _View.checking:
        return _scaffold(_checkingView());
      case _View.addedToTab:
        return _scaffold(_addedToTabView(), title: null);
      case _View.waiting:
        return _scaffold(_waitingView());
    }
  }

  Widget _scaffold(Widget body, {String? title = 'Cobrar'}) => Scaffold(
        appBar: PosAppBar(title: title, showSettings: false),
        body: PosBody(child: body),
      );

  Widget _noAmountView() => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: AppColors.error, size: 48),
          const SizedBox(height: 14),
          const Text('No se pudo generar la invoice.',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          const Text('La orden no tiene monto.',
              style: TextStyle(color: AppColors.muted)),
          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: _goBack, child: const Text('Volver')),
          ),
        ],
      );

  Widget _waitingView() {
    final tabEnabled = appSettings.value.tabEnabled;
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
        Text('$_satsStr sats',
            style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('≈ $_arsStr ARS', style: const TextStyle(color: AppColors.muted)),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: Colors.white, borderRadius: BorderRadius.circular(16)),
          child: QrImageView(data: _invoice, version: QrVersions.auto, size: 220),
        ),
        const SizedBox(height: 20),
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
                onPressed: _goBack,
                child: const Text('Cancelar'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (tabEnabled)
              Expanded(
                child: TextButton.icon(
                  onPressed: _openAddToTab,
                  icon: const Icon(Icons.add_card, size: 18),
                  label: const Text('Agregar a tab'),
                ),
              ),
            Expanded(
              child: TextButton(
                onPressed: () => setState(() => _view = _View.checking),
                child: const Text('Check event'),
              ),
            ),
          ],
        ),
        // Demo-only shortcut to preview the paid state.
        TextButton(
          onPressed: () => setState(() => _view = _View.paid),
          child: const Text('▶ Simular pago recibido (demo)'),
        ),
      ],
    );
  }

  Widget _checkingView() => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 20),
          const Text('Buscando eventos…',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          const Text('Zap e internos…',
              style: TextStyle(color: AppColors.muted)),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => setState(() => _view = _View.waiting),
                  child: const Text('Volver'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => setState(() => _view = _View.waiting),
                  child: const Text('Check event'),
                ),
              ),
            ],
          ),
        ],
      );

  Widget _paidView() => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: const BoxDecoration(
                color: AppColors.primary, shape: BoxShape.circle),
            child: const Icon(Icons.check, size: 56, color: Colors.black),
          ),
          const SizedBox(height: 20),
          const Text('Pago acreditado',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('$_satsStr sats',
              style: const TextStyle(color: AppColors.muted, fontSize: 18)),
          Text('≈ $_arsStr ARS',
              style: const TextStyle(color: AppColors.muted, fontSize: 14)),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: _goBack, child: const Text('Volver')),
          ),
        ],
      );

  Widget _addedToTabView() => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.check_circle, color: AppColors.primary, size: 64),
          const SizedBox(height: 16),
          const Text('Agregado a la cuenta',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(_tabName ?? '',
              style: const TextStyle(color: AppColors.muted, fontSize: 16)),
          const SizedBox(height: 4),
          Text('$_satsStr sats · ≈ $_arsStr ARS',
              style: const TextStyle(color: AppColors.muted)),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: _goBack, child: const Text('Volver')),
          ),
        ],
      );

  void _openAddToTab() {
    final ctrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.background,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            20, 0, 20, MediaQuery.of(ctx).viewInsets.bottom + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Agregar a una cuenta',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                filled: true,
                fillColor: AppColors.surface,
                hintText: 'Nombre del cliente',
                border: OutlineInputBorder(
                    borderSide: BorderSide.none,
                    borderRadius: BorderRadius.all(Radius.circular(12))),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                final name = ctrl.text.trim();
                if (name.isEmpty) return;
                Navigator.of(ctx).pop();
                setState(() {
                  _tabName = name;
                  _view = _View.addedToTab;
                });
              },
              child: const Text('Agregar'),
            ),
          ],
        ),
      ),
    );
  }
}
