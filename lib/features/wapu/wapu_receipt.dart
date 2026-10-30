import 'package:flutter/material.dart' as m;
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../core/widgets.dart';
import '../../domain/config/currencies.dart';
import '../../domain/config/formatter.dart';
import 'wapu_api.dart';

/// Pesos with dots between the thousands and a comma before the cents.
final _pesosAndCents = NumberFormat.decimalPattern('es_AR')
  ..minimumFractionDigits = 2
  ..maximumFractionDigits = 2;

final _date = DateFormat('yyyy-MM-dd HH:mm:ss');

/// [cents] as pesos, always with the two decimals and no sign: `1500037` is
/// `15.000,37`.
String formatPesos(int cents) => _pesosAndCents.format(cents / 100);

/// [destination] as a receipt says it: a lightning address in full, and a
/// BOLT11 invoice (it starts with `ln` and has no `@`) as its first 12
/// characters, an ellipsis and its last 8.
String shortDestination(String destination) {
  final invoice = destination.length > 20 &&
      !destination.contains('@') &&
      destination.toLowerCase().startsWith('ln');
  return invoice
      ? '${destination.substring(0, 12)}…'
          '${destination.substring(destination.length - 8)}'
      : destination;
}

/// The receipt of an order that is over: the sats, when, where they went, the
/// order id (to copy, or to read as a QR), what it cost and what was paid. It
/// is for COMPLETED and SETTLED_TO_BALANCE orders, and for any other as one
/// that expired: no ARS came in, so the deposit is the one that was expected.
///
/// Values are Material [m.Text] or [SelectableText]: the app's [Text] would
/// uppercase an address or an id and squeeze it onto one line.
class WapuReceipt extends StatelessWidget {
  const WapuReceipt({super.key, required this.order});

  final WapuOrder order;

  @override
  Widget build(BuildContext context) {
    final o = order;
    final created = o.createdAt;
    final (status, deposit) = switch (o.status) {
      'COMPLETED' => ('Completada', 'Depósito del cliente'),
      'SETTLED_TO_BALANCE' => (
          'Acreditada en saldo Wapu',
          'Depósito del cliente'
        ),
      _ => ('Vencida', 'Depósito esperado'),
    };
    final divider =
        Divider(height: 24, color: AppColors.muted.withValues(alpha: 0.3));
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      // A Material, not a colored Container, so the buttons' ink shows on it.
      child: Material(
        key: const Key('wapu-receipt'),
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _row(context.tr(o.status == 'COMPLETED' ? 'Comprado' : 'Monto'),
                  _sats(o.purchasedSats)),
              if (created != null)
                _row(context.tr('Fecha'), _date.format(created.toLocal())),
              divider,
              _row(context.tr('Estado'), context.tr(status)),
              divider,
              _row(context.tr('Para'), shortDestination(o.payoutAddress)),
              divider,
              _idRow(context),
              _row(context.tr('Comisión de la operación'),
                  _sats(o.networkFeeOut)),
              _row(context.tr(deposit), '${formatPesos(o.amountArsCents)} ARS'),
              // The sats the customer received, as in the headline: fewer than
              // the purchased ones, by the fee and Wapu's commission.
              _row(context.tr('Total'), _sats(o.amountOut)),
            ],
          ),
        ),
      ),
    );
  }

  String _sats(int sats) => '${formatToPreference(Currency.sat, sats)} SAT';

  /// A label on the left, muted, and its value on the right. When they do not
  /// fit side by side (a long address, a phone at the app's large text) the
  /// value drops to the next line, as in the lines of the amount step.
  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          children: [
            m.Text(label,
                style: const TextStyle(fontSize: 16, color: AppColors.muted)),
            m.Text(
              value,
              textAlign: TextAlign.right,
              softWrap: true,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );

  /// The label, then the id with the buttons that copy it and show it as a QR.
  Widget _idRow(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            m.Text(context.tr('ID de transacción'),
                style: const TextStyle(fontSize: 16, color: AppColors.muted)),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    order.id,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  key: const Key('wapu-copy-id'),
                  tooltip: context.tr('Copiar').toUpperCase(),
                  icon: const Icon(Icons.copy_rounded),
                  onPressed: () => _copyId(context),
                ),
                IconButton(
                  key: const Key('wapu-id-qr'),
                  tooltip: context.tr('Mostrar QR').toUpperCase(),
                  icon: const Icon(Icons.qr_code_2),
                  onPressed: () => _showQr(context),
                ),
              ],
            ),
          ],
        ),
      );

  void _copyId(BuildContext context) {
    Clipboard.setData(ClipboardData(text: order.id));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(context.tr('ID copiado')),
          duration: const Duration(seconds: 1)),
    );
  }

  /// The id as a QR on a white card, with the id under it.
  void _showQr(BuildContext context) {
    final qr = QrValidator.validate(
      data: order.id,
      version: QrVersions.auto,
    ).qrCode!;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.onDark,
                borderRadius: BorderRadius.circular(16),
              ),
              // A dialog asks its content for its intrinsic width, which the
              // LayoutBuilder of BakedQr cannot answer: a fixed box does.
              child: SizedBox.square(
                dimension: 240,
                child: BakedQr(
                  key: const Key('wapu-id-qr-code'),
                  size: 240,
                  moduleCount: qr.moduleCount,
                  painter: QrPainter.withQr(qr: qr, gapless: true),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SelectableText(
              order.id,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, color: AppColors.muted),
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('wapu-id-qr-close'),
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(ctx.tr('Cerrar')),
          ),
        ],
      ),
    );
  }
}
