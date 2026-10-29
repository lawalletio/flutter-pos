import 'package:flutter/material.dart' as m;
import 'package:go_router/go_router.dart';

import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../core/widgets.dart';
import '../../domain/config/currencies.dart';
import '../../domain/config/formatter.dart';
import '../../domain/config/session.dart';
import 'wapu_account.dart';
import 'wapu_api.dart';
import 'wapu_error_text.dart';
import 'wapu_status_view.dart' show formatArsCents;

/// The orders of the signed-in POS user's Wapu account, the ones still in
/// progress first. Choosing one pops with its id, and the sale follows it.
///
/// This is where the operator looks after a create whose outcome is unknown, so
/// a list that could not be read is an error with a way to ask again, and never
/// an empty history: "no orders" would say that nothing was created.
///
/// What the operator reads out (amounts, the address) is Material [m.Text], not
/// the app's [Text], which would uppercase it and squeeze it into one line.
class WapuHistoryScreen extends StatefulWidget {
  const WapuHistoryScreen({super.key});

  @override
  State<WapuHistoryScreen> createState() => _WapuHistoryScreenState();
}

class _WapuHistoryScreenState extends State<WapuHistoryScreen> {
  /// Whose orders these are, for as long as the screen is open.
  final _merchant = merchantAddress.value;

  /// The orders, in-progress ones first. Null while they load, and when they
  /// could not be read.
  List<WapuOrder>? _orders;

  /// Why they could not be read: the [WapuApiException] of the call, or the
  /// Spanish copy (translated when drawn) of a problem of our own.
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    List<WapuOrder>? orders;
    Object? error;
    try {
      final credentials = await wapuAccounts.load(_merchant);
      if (credentials == null) {
        error = 'Configurá tu API key de Wapu';
      } else {
        final all = await wapuApiFor(credentials.baseUrl, credentials.apiKey)
            .orders();
        orders = _inProgressFirst(all);
      }
    } on WapuApiException catch (e) {
      error = e;
    } catch (_) {
      error = const WapuApiException(''); // the generic copy, with no detail
    }
    if (!mounted) return;
    setState(() {
      _orders = orders;
      _error = error;
    });
  }

  void _retry() {
    setState(() => _error = null);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PosAppBar(
        title: context.tr('Historial'),
        showSettings: false,
        showSync: false,
        showInvoiceDebug: false,
      ),
      body: PosBody(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    final error = _error;
    if (error != null) return _failed(context, error);
    final orders = _orders;
    if (orders == null) return const Center(child: CircularProgressIndicator());
    if (orders.isEmpty) {
      return Center(
        child: Text(
          context.tr('Todavía no hay órdenes'),
          textAlign: TextAlign.center,
          softWrap: true,
          style: const TextStyle(color: AppColors.muted),
        ),
      );
    }
    final now = DateTime.now();
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: orders.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, i) => _row(context, orders[i], now),
    );
  }

  /// Why the orders could not be read, with the button that asks again. It
  /// scrolls: a long reason on a short screen must not overflow.
  Widget _failed(BuildContext context, Object error) {
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            error is WapuApiException
                ? WapuErrorText(error)
                : m.Text(
                    context.tr(error.toString()),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.error),
                  ),
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('wapu-history-retry'),
              onPressed: _retry,
              child: Text(context.tr('Reintentar')),
            ),
          ],
        ),
      ),
    );
  }

  /// One order: what the customer pays and where it stands, then what they get
  /// and where it goes. The whole row is the button.
  Widget _row(BuildContext context, WapuOrder o, DateTime now) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('wapu-order-${o.id}'),
        onTap: () => context.pop(o.id),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // One line: a big amount shrinks instead of wrapping.
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: m.Text(
                        formatArsCents(o.amountArsCents),
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  m.Text(
                    context.tr(_label(o, now)),
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: o.isInProgress(now)
                          ? AppColors.primary
                          : AppColors.muted,
                    ),
                  ),
                ],
              ),
              m.Text('${formatToPreference(Currency.sat, o.amountOut)} sats'),
              m.Text(
                o.payoutAddress,
                softWrap: true,
                style: const TextStyle(color: AppColors.muted, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// [all] with the orders still in progress first. Each group keeps the order
/// the API listed it in.
List<WapuOrder> _inProgressFirst(List<WapuOrder> all) {
  final now = DateTime.now();
  return [
    ...all.where((o) => o.isInProgress(now)),
    ...all.where((o) => !o.isInProgress(now)),
  ];
}

/// Where [o] stands, in a word (a Spanish source text). A status that is not
/// known here is said as the backend says it. A CREATED order that is not in
/// progress was never funded and its window has closed: the status view calls
/// that expired too.
String _label(WapuOrder o, DateTime now) {
  if (o.isInProgress(now)) return 'En curso';
  return switch (o.status) {
    'COMPLETED' => 'Completada',
    'CREATED' || 'EXPIRED' => 'Vencida',
    'SETTLED_TO_BALANCE' => 'En tu saldo',
    _ => o.status,
  };
}
