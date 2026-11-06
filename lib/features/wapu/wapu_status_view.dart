import 'package:flutter/material.dart' as m;
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../domain/config/currencies.dart';
import '../../domain/config/formatter.dart';
import 'wapu_api.dart';

/// Pesos with dots between the thousands and a comma before the cents.
final _pesosAndCents = NumberFormat.decimalPattern('es_AR')
  ..minimumFractionDigits = 2
  ..maximumFractionDigits = 2;

/// [cents] as pesos, always with the two decimals: `1500037` is `$ 15.000,37`.
String formatArsCents(int cents) => '\$ ${_pesosAndCents.format(cents / 100)}';

/// [d] as `mm:ss`. Time that has run out is `00:00`.
String formatCountdown(Duration d) {
  final seconds = d.isNegative ? 0 : d.inSeconds;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(seconds ~/ 60)}:${two(seconds % 60)}';
}

/// One order, for the operator to read: what the customer has to do, or what
/// became of the payment. It only shows. [onRequestFunding] and [onNewSale]
/// are the screen's to carry out, and [now] is the screen's clock, so the
/// countdown moves when the screen repaints with a later one.
///
/// What the operator reads out or copies (alias, amounts, ids, hashes) is
/// Material [m.Text] or [SelectableText]: the app's [Text] would uppercase it
/// and squeeze it onto one line. The app's [Text] is for the buttons only.
class WapuStatusView extends StatelessWidget {
  const WapuStatusView({
    super.key,
    required this.order,
    required this.now,
    this.onRequestFunding,
    this.onNewSale,
    this.busy = false,
  });

  final WapuOrder order;
  final DateTime now;

  /// Asks for the bank details of a CREATED order.
  final VoidCallback? onRequestFunding;

  /// Starts the next sale. Offered once the order is over.
  final VoidCallback? onNewSale;

  /// The bank details are being asked for: the button waits.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final o = order;
    final List<Widget> body = switch ((o.status, o.payoutStatus)) {
      ('FUNDING_ISSUED', _) => _waiting(context),
      ('CREATED', _) when o.isInProgress(now) => _created(context),
      ('EXPIRED', _) when o.watchPending => _lateWatch(context),
      ('CREATED' || 'EXPIRED', _) => _closed(context),
      ('EXECUTED', 'review') => _review(context),
      // The ARS was received, so any other payout status (sending, or one that
      // is not known here) is the sats on their way, never the raw status.
      ('EXECUTED', _) => [
          _title(context.tr('Pago recibido. Enviando los sats…')),
        ],
      ('COMPLETED', _) => _completed(context),
      ('SETTLED_TO_BALANCE', _) => _settled(context),
      _ => [_title(o.status)],
    };
    // It scrolls: on a short screen the bank details are taller than it is.
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: body,
      ),
    );
  }

  List<Widget> _waiting(BuildContext context) {
    final alias = order.alias;
    final expiresAt = order.expiresAt;
    return [
      _title(context.tr('Esperando la transferencia')),
      // The alias only: the CVU is not shown.
      if (alias != null)
        _bankRow(
            context, const Key('wapu-copy-alias'), context.tr('Alias'), alias),
      _bankRow(
        context,
        const Key('wapu-copy-amount'),
        context.tr('Monto exacto'),
        formatArsCents(order.amountArsCents),
        // A plain decimal, as a bank app takes it: no separators.
        copy: (order.amountArsCents / 100).toStringAsFixed(2),
      ),
      _note(context.tr('Transferí exactamente este monto, con centavos')),
      if (expiresAt != null)
        _note(
          '${context.tr('Vence en ')}'
          '${formatCountdown(expiresAt.difference(now))}',
          color: AppColors.onDark,
        ),
    ];
  }

  List<Widget> _created(BuildContext context) => [
        _title(context.tr('Orden creada')),
        const SizedBox(height: 16),
        FilledButton(
          key: const Key('wapu-fund'),
          onPressed: busy ? null : onRequestFunding,
          child: busy
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 3),
                )
              : Text(
                  context.tr('Pedir datos de transferencia'),
                  softWrap: true,
                  textAlign: TextAlign.center,
                ),
        ),
      ];

  List<Widget> _lateWatch(BuildContext context) {
    final until = order.lateWatchUntil;
    return [
      _title(context.tr('Venció el plazo')),
      if (until != null)
        _note(
          '${context.tr('Si el cliente ya transfirió, lo seguimos buscando hasta las ')}'
          '${DateFormat.Hm().format(until.toLocal())}',
        ),
    ];
  }

  List<Widget> _closed(BuildContext context) =>
      [_title(context.tr('Orden vencida')), _newSale(context)];

  List<Widget> _review(BuildContext context) => [
        _title(context.tr('En revisión')),
        SelectableText(
          '${context.tr('Guardá el ID de la orden: ')}${order.id}',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16, color: AppColors.muted),
        ),
      ];

  List<Widget> _completed(BuildContext context) {
    final hash = order.paymentHash;
    final sats = formatToPreference(Currency.sat, order.amountOut);
    return [
      _title(
        '${context.tr('¡Listo! El cliente recibió ')}$sats sats',
        color: AppColors.primary,
      ),
      if (hash != null)
        SelectableText(
          hash,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: AppColors.muted),
        ),
      _newSale(context),
    ];
  }

  List<Widget> _settled(BuildContext context) => [
        _title(context.tr('No se pudieron enviar los sats'),
            color: AppColors.error),
        _note(context.tr('El monto quedó en tu saldo de Wapu.')),
        _newSale(context),
      ];

  /// Where the order stands, in a line big enough to read across the counter.
  Widget _title(String text, {Color? color}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: m.Text(
          text,
          textAlign: TextAlign.center,
          softWrap: true,
          style: TextStyle(
              fontSize: 24, fontWeight: FontWeight.w700, color: color),
        ),
      );

  Widget _note(String text, {Color color = AppColors.muted}) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: m.Text(
          text,
          textAlign: TextAlign.center,
          softWrap: true,
          style: TextStyle(fontSize: 16, color: color),
        ),
      );

  /// A label over its [value], with the button that copies it. [copy] is what
  /// the clipboard gets when that is not what is shown.
  Widget _bankRow(
    BuildContext context,
    Key copyKey,
    String label,
    String value, {
    String? copy,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                m.Text(label, style: const TextStyle(color: AppColors.muted)),
                m.Text(
                  value,
                  softWrap: true,
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton(
            key: copyKey,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 48),
              textStyle:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            onPressed: () => _copy(context, copy ?? value),
            child: Text(context.tr('Copiar')),
          ),
        ],
      ),
    );
  }

  void _copy(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(context.tr('Copiado')),
          duration: const Duration(seconds: 1)),
    );
  }

  /// The way out of an order that is over.
  Widget _newSale(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 24),
        child: FilledButton(
          key: const Key('wapu-new-sale-big'),
          onPressed: onNewSale,
          child: Text(context.tr('Nueva venta')),
        ),
      );
}
