import '../../core/i18n.dart';
import '../../core/pin_dialog.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../core/widgets.dart';
import '../../domain/config/miniapp_pin.dart';

/// Sets or changes the PIN that locks the miniapps. Opening it already asked
/// for the current PIN (when there is one), so changing only asks for the new.
class PinSettingsScreen extends StatelessWidget {
  const PinSettingsScreen({super.key});

  Future<void> _setPin(BuildContext context) async {
    final first = await showPinDialog(
      context,
      title: 'Nuevo PIN',
      action: 'Siguiente',
      check: (pin) =>
          RegExp(r'^\d{4,8}$').hasMatch(pin) ? null : 'Entre 4 y 8 dígitos',
    );
    if (first == null || !context.mounted) return;
    final again = await showPinDialog(
      context,
      title: 'Repetí el PIN',
      action: 'Guardar',
      check: (pin) => pin == first ? null : 'Los PIN no coinciden',
    );
    if (again == null) return;
    await setMiniappPin(again);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.tr('PIN guardado'))));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PosAppBar(
          title: context.tr('Configuración de PIN'), showSettings: false),
      body: ValueListenableBuilder<String?>(
        valueListenable: miniappPin,
        builder: (context, pin, _) => PosBody(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 20),
                child: Text(
                  context.tr(pin == null
                      ? 'Sin PIN: las miniapps se cierran sin pedirlo.'
                      : 'Las miniapps se desbloquean con tu PIN.'),
                  style: const TextStyle(color: AppColors.muted, fontSize: 15),
                ),
              ),
              FilledButton.icon(
                key: const Key('pin-set'),
                onPressed: () => _setPin(context),
                icon: const Icon(Icons.pin_outlined, size: 22),
                label: Text(
                    context.tr(pin == null ? 'SETEAR PIN' : 'CAMBIAR PIN')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
