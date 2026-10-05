import 'package:flutter/material.dart';

import '../domain/config/miniapp_pin.dart';
import 'i18n.dart';

/// Asks for a PIN and returns it once [check] accepts it, or null on cancel.
/// [check] returns the (Spanish) error to show, or null to accept.
Future<String?> showPinDialog(
  BuildContext context, {
  required String title,
  required String action,
  required String? Function(String pin) check,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _PinDialog(title: title, action: action, check: check),
  );
}

/// True when the miniapp PIN was entered, or straight away when none is set.
Future<bool> confirmMiniappPin(BuildContext context,
    {required String action}) async {
  final expected = miniappPin.value;
  if (expected == null) return true;
  final pin = await showPinDialog(
    context,
    title: 'Ingresá el PIN',
    action: action,
    check: (pin) => pin == expected ? null : 'PIN incorrecto',
  );
  return pin != null;
}

class _PinDialog extends StatefulWidget {
  const _PinDialog({
    required this.title,
    required this.action,
    required this.check,
  });

  final String title;
  final String action;
  final String? Function(String pin) check;

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _pin = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  void _submit() {
    final error = widget.check(_pin.text);
    if (error == null) {
      Navigator.of(context).pop(_pin.text);
    } else {
      setState(() => _error = error);
      _pin.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.tr(widget.title)),
      content: TextField(
        key: const Key('miniapp-pin'),
        controller: _pin,
        autofocus: true,
        obscureText: true,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 28, letterSpacing: 8),
        decoration: InputDecoration(
          errorText: _error == null ? null : context.tr(_error!),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton(
              onPressed: _submit,
              child: Text(context.tr(widget.action)),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('pin-cancel'),
              onPressed: () => Navigator.of(context).pop(),
              child: Text(context.tr('Cancelar')),
            ),
          ],
        ),
      ],
    );
  }
}
