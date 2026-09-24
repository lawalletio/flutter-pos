import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../domain/order/current_order.dart';
import '../../domain/order/invoice_debug_store.dart';
import '../../domain/order/orders_store.dart';
import 'recheck_modal.dart';

const Color _amber = Color(0xFFE0A82E);
final DateFormat _df = DateFormat('dd/MM · HH:mm:ss');

/// On-device log of every bolt11 the provider returned, including ones the
/// payment screen later replaced. Each row can be verified on its own.
class InvoiceDebugScreen extends StatelessWidget {
  const InvoiceDebugScreen({super.key});

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(context.tr('¿Borrar el historial de invoices?')),
        content: Text(context.tr(
            'Se borran solo las invoices de depuración. Las órdenes no se tocan.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.tr('Cancelar'),
                style: const TextStyle(color: AppColors.muted)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.tr('Borrar')),
          ),
        ],
      ),
    );
    if (ok == true) invoiceDebugStore.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PosAppBar(
        title: context.tr('Invoices generadas'),
        showInvoiceDebug: false,
      ),
      body: ValueListenableBuilder<List<GeneratedInvoice>>(
        valueListenable: invoiceDebugStore.notifier,
        builder: (context, entries, _) {
          if (entries.isEmpty) {
            return PosBody(child: _empty(context));
          }
          final groups = _groups(entries);
          return PosBody(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  context.tr(
                      'Cada respuesta del proveedor queda acá, aunque el QR haya pasado a otra.'),
                  style: const TextStyle(color: AppColors.muted, fontSize: 13),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: groups.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 16),
                    itemBuilder: (context, i) =>
                        _ChargeGroup(entries: groups[i]),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.error,
                    side: BorderSide(color: AppColors.error.withValues(alpha: 0.5)),
                  ),
                  onPressed: () => _confirmClear(context),
                  icon: const Icon(Icons.delete_outline),
                  label: Text(context.tr('Borrar historial')),
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _empty(BuildContext context) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.receipt_long, color: AppColors.muted, size: 48),
          const SizedBox(height: 14),
          Text(context.tr('Todavía no se generó ninguna invoice.'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted, fontSize: 16)),
        ],
      );
}

/// Newest charge first. Invoices inside a charge stay in generation order so a
/// slow reply that arrived last is visible at the bottom of its group.
List<List<GeneratedInvoice>> _groups(List<GeneratedInvoice> entries) {
  final byScreen = <int, List<GeneratedInvoice>>{};
  for (final e in entries) {
    byScreen.putIfAbsent(e.screenId, () => []).add(e);
  }
  final groups = byScreen.values.toList();
  for (final g in groups) {
    g.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }
  groups.sort((a, b) {
    final aAt = a.map((e) => e.createdAt).reduce((x, y) => x > y ? x : y);
    final bAt = b.map((e) => e.createdAt).reduce((x, y) => x > y ? x : y);
    return bAt.compareTo(aAt);
  });
  return groups;
}

bool _wasReplaced(GeneratedInvoice entry, List<GeneratedInvoice> charge) =>
    charge.any((o) => o.id != entry.id && o.applied && o.createdAt > entry.createdAt);

class _ChargeGroup extends StatelessWidget {
  const _ChargeGroup({required this.entries});

  final List<GeneratedInvoice> entries;

  @override
  Widget build(BuildContext context) {
    final several = entries.length > 1;
    final first = entries.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(_df.format(DateTime.fromMillisecondsSinceEpoch(first.createdAt)),
                style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
            const Spacer(),
            Text(
              several
                  ? '${entries.length} ${context.tr('invoices en este cobro')}'
                  : context.tr('1 invoice en este cobro'),
              style: TextStyle(
                color: several ? _amber : AppColors.muted,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < entries.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _InvoiceCard(
            entry: entries[i],
            replaced: _wasReplaced(entries[i], entries),
          ),
        ],
      ],
    );
  }
}

class _InvoiceCard extends StatelessWidget {
  const _InvoiceCard({required this.entry, required this.replaced});

  final GeneratedInvoice entry;
  final bool replaced;

  Future<void> _verify(BuildContext context) async {
    final paid = await showRecheckModal(
      context,
      OrderRecord(
        id: entry.id,
        createdAt: entry.createdAt,
        amountSats: entry.amountSats,
        summary: entry.summary,
        verifyUrl: entry.verifyUrl,
        invoice: entry.invoice,
        zapPubkey: entry.zapPubkey,
        zapRelays: entry.zapRelays,
        zapOrderId: entry.zapOrderId,
        items: entry.items,
        couponId: entry.couponId,
        couponName: entry.couponName,
        discountSats: entry.discountSats,
      ),
    );
    await invoiceDebugStore.markChecked(entry.id, paid);
  }

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: entry.invoice));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(context.tr('Invoice copiada')),
      duration: const Duration(seconds: 1),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text('${entry.amountSats} sats',
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w700)),
                ),
                Text(_df.format(DateTime.fromMillisecondsSinceEpoch(entry.createdAt)),
                    style: const TextStyle(color: AppColors.muted, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _chip(context, _reasonLabel(context, entry.reason), AppColors.muted),
                if (entry.stale)
                  _chip(context, context.tr('Respuesta vieja, ignorada'), _amber)
                else if (entry.applied)
                  _chip(context, context.tr('Mostrada'), AppColors.primary)
                else
                  _chip(context, context.tr('Pantalla cerrada'), AppColors.error),
                if (replaced) _chip(context, context.tr('Reemplazada'), _amber),
                if (entry.liveScreens > 1)
                  _chip(context, context.tr('Dos pantallas de cobro'), _amber),
              ],
            ),
            const SizedBox(height: 12),
            Text(context.tr('Orden'),
                style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6)),
            const SizedBox(height: 4),
            if (entry.items.isEmpty)
              Text(entry.summary.isEmpty ? context.tr('Cobro manual') : entry.summary,
                  style: const TextStyle(fontSize: 15))
            else
              for (final it in entry.items) _itemLine(it),
            if (entry.couponName != null) ...[
              const SizedBox(height: 4),
              Text('${context.tr('Cupón')}: ${entry.couponName}'
                  '${entry.discountSats > 0 ? ' · −${entry.discountSats} sats' : ''}',
                  style: const TextStyle(color: AppColors.primary, fontSize: 13)),
            ],
            const SizedBox(height: 10),
            Text(_invoicePreview(entry.invoice),
                style: const TextStyle(
                    color: AppColors.muted, fontSize: 12, fontFamily: 'monospace')),
            const SizedBox(height: 4),
            Text(
              'gen ${entry.generation}/${entry.latestGeneration}'
              '${entry.orderId == null ? '' : ' · ${entry.orderId}'}'
              ' · ${entry.supportsLud21 ? 'LUD-21' : context.tr('sin LUD-21')}'
              ' · ${entry.supportsNip57 ? 'NIP-57' : context.tr('sin zap')}',
              style: const TextStyle(color: AppColors.muted, fontSize: 11),
            ),
            if (entry.lastCheckedAt != null) ...[
              const SizedBox(height: 6),
              Text(
                entry.lastSettled == true
                    ? context.tr('Pago confirmado')
                    : context.tr('Sin confirmar'),
                style: TextStyle(
                  color: entry.lastSettled == true ? AppColors.primary : _amber,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      textStyle: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    onPressed: () => _copy(context),
                    child: Text(context.tr('Copiar')),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      textStyle: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                    onPressed: (entry.supportsLud21 || entry.supportsNip57)
                        ? () => _verify(context)
                        : null,
                    child: Text(context.tr('Verificar')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _itemLine(OrderItem it) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text('${it.qty}× ${it.name}',
            style: const TextStyle(fontSize: 15)),
      );

  Widget _chip(BuildContext context, String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label,
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.w700)),
      );
}

String _reasonLabel(BuildContext context, String reason) {
  switch (reason) {
    case 'init':
      return context.tr('Apertura');
    case 'coupon':
      return context.tr('Cupón');
    case 'remove-coupon':
      return context.tr('Quitar cupón');
    case 'retry':
      return context.tr('Reintento');
    default:
      return reason;
  }
}

String _invoicePreview(String pr) {
  if (pr.length <= 28) return pr;
  return '${pr.substring(0, 18)}…${pr.substring(pr.length - 8)}';
}
