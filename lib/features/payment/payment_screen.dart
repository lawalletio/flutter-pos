import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/lnurl/lnurl_service.dart';
import '../../data/mock/mock_data.dart';
import '../../data/nostr/relay_pool.dart';
import '../../data/pricing/pricing_service.dart';
import '../../domain/config/currencies.dart';
import '../../domain/config/formatter.dart';
import '../../domain/config/session.dart';
import '../../domain/config/settings_state.dart';
import '../../domain/order/current_order.dart';
import '../../domain/order/order_reset.dart';
import '../../domain/order/orders_store.dart';
import '../../domain/order/receipt_printer.dart';
import '../../platform/nfc_channel.dart';
import '../orders/recheck_modal.dart';
import 'invoice_view.dart';
import 'nfc_charging_view.dart';
import 'success_view.dart';

/// Payment — generates a REAL bolt11 invoice from the merchant Lightning Address
/// callback (LUD-16 → LNURL-pay), shows it as a QR, and polls the LUD-21 verify
/// URL to detect settlement. Falls back to a demo "simular pago" button so the
/// paid celebration is reachable in the preview without a real payer.
class PaymentScreen extends StatefulWidget {
  final int amountSats;
  final bool initiallyPaid;
  final bool openAddTab; // preview affordance: auto-open the add-to-tab sheet
  final String? back;
  const PaymentScreen({
    super.key,
    required this.amountSats,
    this.initiallyPaid = false,
    this.openAddTab = false,
    this.back,
  });
  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

enum _View { waiting, paid, addedToTab }

class _PaymentScreenState extends State<PaymentScreen> {
  late _View _view = widget.initiallyPaid ? _View.paid : _View.waiting;
  String? _tabName;
  int? _tabTotalSats;

  // Real invoice state.
  String? _invoice; // bolt11
  String? _verifyUrl; // LUD-21
  String? _invoiceError;
  bool _printed = false;
  bool _collecting = false; // pulling payment from a tapped card
  bool _nfcAvailable = false;
  StreamSubscription<String>? _nfcSub;
  Timer? _poll;
  ZapWatcher? _zap; // NIP-57 zap-receipt subscription (live relay connection)
  String? _orderId; // recorded order in the persisted store

  // Card-charging animation state.
  double _collectProgress = 0;
  int _collectStepIndex = 0; // active task in the NFC charging checklist

  String _satsOf(int sats) => formatToPreference(Currency.sat, sats);
  String _arsOf(int sats) => formatToPreference(
      Currency.ars, pricing.satsToFiat(sats, Currency.ars) ?? 0);
  String get _satsStr => _satsOf(widget.amountSats);
  String get _arsStr => _arsOf(widget.amountSats);

  @override
  void initState() {
    super.initState();
    pricing.ensureLoaded();
    pricing.notifier.addListener(_onRates);
    if (!widget.initiallyPaid && widget.amountSats > 0) {
      _fetchInvoice();
    }
    if (widget.openAddTab && widget.amountSats > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openAddToTab());
    }
    if (widget.initiallyPaid) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _printReceipt());
    }
  }

  /// Transition to the paid state and print the receipt (once).
  void _markPaid() {
    if (_view == _View.paid) return;
    _stopNfc();
    _poll?.cancel();
    if (_orderId != null) ordersStore.markPaid(_orderId!);
    // Clear the order immediately on full payment so returning to the menu — by
    // the "Volver" button, the app bar back, or the Android hardware back — always
    // shows an empty cart (go_router keeps the menu page alive otherwise).
    resetOrder();
    setState(() {
      _collecting = false;
      _view = _View.paid;
    });
    _printReceipt();
  }

  void _stopNfc() {
    _nfcSub?.cancel();
    _nfcSub = null;
    NfcChannel.stopSession();
    // Also tear down the NIP-57 relay subscription (shared teardown point).
    _zap?.dispose();
    _zap = null;
  }

  /// Auto-print the receipt on the ZCS printer. No-op where there's no printer
  /// (e.g. web preview) — the channel returns gracefully.
  Future<void> _printReceipt() async {
    if (_printed) return;
    _printed = true;
    // Print from the order snapshot (the live cart is already cleared by
    // resetOrder() at this point); fall back to the live cart for the preview
    // `initiallyPaid` path, which never records an order.
    final items = _recordedItems() ?? currentOrderItems.value;
    await printOrderReceipt(
      amountSats: widget.amountSats,
      items: items,
      thankYouMessage: context.tr('Gracias por su pago'),
    );
  }

  /// The line items snapshotted on this screen's recorded order, if any.
  List<OrderItem>? _recordedItems() {
    final id = _orderId;
    if (id == null) return null;
    for (final o in ordersStore.notifier.value) {
      if (o.id == id) return o.items;
    }
    return null;
  }

  @override
  void dispose() {
    _poll?.cancel();
    _stopNfc();
    pricing.notifier.removeListener(_onRates);
    super.dispose();
  }

  /// Arm the card reader while the payment is pending. No button — reader mode
  /// stays active and each tap is delivered via the tag stream.
  Future<void> _startAutoNfc() async {
    if (_nfcSub != null) return;
    _nfcAvailable = await NfcChannel.isAvailable();
    if (!_nfcAvailable) return;
    if (mounted) setState(() {});
    await NfcChannel.startSession();
    _nfcSub = NfcChannel.tags().listen((cardUrl) {
      if (!mounted || _view != _View.waiting || _collecting) return;
      _collectFromCard(cardUrl);
    });
  }

  /// A card was tapped: show the NFC charging animation while pulling the
  /// payment (LNURL-withdraw), updating the step label + progress bar.
  Future<void> _collectFromCard(String cardUrl) async {
    final inv = _invoice;
    if (inv == null) return;
    setState(() {
      _collecting = true;
      _collectStepIndex = 0;
      _collectProgress = 0.18;
    });
    try {
      if (mounted) {
        setState(() {
          _collectStepIndex = 1;
          _collectProgress = 0.42;
        });
      }
      await lnurl.payWithCard(cardUrl, inv);
      // Submitted — confirm settlement (a few seconds), else leave it to polling.
      if (mounted) {
        setState(() {
          _collectStepIndex = 2;
          _collectProgress = 0.66;
        });
      }
      final url = _verifyUrl;
      var settled = false;
      if (url != null) {
        for (var i = 0; i < 12 && mounted; i++) {
          if (await lnurl.checkSettled(url)) {
            settled = true;
            break;
          }
          if (mounted) {
            setState(() =>
                _collectProgress = (0.66 + i * 0.024).clamp(0.0, 0.95));
          }
          await Future<void>.delayed(const Duration(milliseconds: 800));
        }
      }
      if (!mounted) return;
      if (settled) {
        setState(() {
          _collectProgress = 1;
          _collectStepIndex = 3; // all tasks done
        });
        _markPaid();
      } else {
        setState(() => _collecting = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(context.tr('Pago enviado, esperando confirmación…'))));
      }
    } on LnurlException catch (e) {
      if (!mounted) return;
      setState(() => _collecting = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: AppColors.error));
    } catch (_) {
      if (mounted) setState(() => _collecting = false);
    }
  }

  void _onRates() {
    if (mounted) setState(() {});
  }

  Future<void> _fetchInvoice() async {
    setState(() {
      _invoiceError = null;
    });
    try {
      final inv = await lnurl.requestInvoice(
        merchantAddress.value,
        widget.amountSats,
        relays: appSettings.value.relays,
      );
      if (!mounted) return;
      setState(() {
        _invoice = inv.pr;
        _verifyUrl = inv.verify;
      });
      _recordOrder(inv); // persist a pending order (re-checkable later)
      _startPolling();
      _startZapWatch(inv); // NIP-57: watch relays for the zap receipt
      _startAutoNfc(); // arm the card reader while pending
    } on LnurlException catch (e) {
      if (!mounted) return;
      setState(() {
        _invoiceError = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _invoiceError = 'No se pudo generar la invoice';
      });
    }
  }

  void _startPolling() {
    final url = _verifyUrl;
    if (url == null) return; // provider without LUD-21 verify
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (t) async {
      if (!mounted || _view != _View.waiting) return;
      try {
        if (await lnurl.checkSettled(url)) {
          if (!mounted) return;
          t.cancel();
          _markPaid();
        }
      } catch (_) {/* keep polling */}
    });
  }

  /// NIP-57: when the provider supports zaps, keep a live relay subscription open
  /// while the invoice is pending and mark paid the moment the kind-9735 zap
  /// receipt for this invoice lands (in parallel with the LUD-21 poll).
  void _startZapWatch(LnurlInvoice inv) {
    if (!inv.zapEnabled) return;
    _zap?.dispose();
    _zap = ZapWatcher(
      relays: inv.zapRelays,
      zapperPubkey: inv.zapPubkey!,
      invoice: inv.pr,
      orderId: inv.zapOrderId,
      onPaid: () {
        if (mounted && _view == _View.waiting) _markPaid();
      },
    )..start();
  }

  /// Persist a pending order carrying everything needed to re-verify it later
  /// (LUD-21 verify URL + NIP-57 zap details).
  void _recordOrder(LnurlInvoice inv) {
    _orderId = 'o${DateTime.now().microsecondsSinceEpoch}';
    ordersStore.add(OrderRecord(
      id: _orderId!,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      amountSats: widget.amountSats,
      summary: _orderSummary(),
      verifyUrl: inv.verify,
      invoice: inv.pr,
      zapPubkey: inv.zapPubkey,
      zapRelays: inv.zapRelays,
      zapOrderId: inv.zapOrderId,
      // Snapshot the cart now: resetOrder() clears the live cart on payment,
      // before the receipt is printed and so the order can be re-printed later.
      items: currentOrderItems.value.toList(),
    ));
  }

  String _orderSummary() {
    final items = currentOrderItems.value;
    if (items.isEmpty) return context.tr('Cobro manual');
    return items.map((it) => '${it.qty}× ${it.name}').join(', ');
  }

  /// "Check event" — re-verify this order via the animated modal that steps
  /// through LUD-21 then NIP-57 with a progress bar; transition to paid if the
  /// modal confirmed settlement.
  Future<void> _checkEvent() async {
    final id = _orderId;
    if (id == null) return;
    OrderRecord? order;
    for (final o in ordersStore.notifier.value) {
      if (o.id == id) {
        order = o;
        break;
      }
    }
    if (order == null) return;
    await showRecheckModal(context, order);
    if (!mounted) return;
    final confirmed =
        ordersStore.notifier.value.any((o) => o.id == id && o.isPaid);
    if (confirmed && _view == _View.waiting) _markPaid();
  }

  void _goBack() {
    _poll?.cancel();
    _stopNfc();
    if (widget.back != null && widget.back!.isNotEmpty) {
      context.go(widget.back!);
    } else {
      context.go('/hub');
    }
  }

  /// Payment finished (paid or moved to a tab): clear the order and return.
  void _finishAndBack() {
    resetOrder();
    _goBack();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.amountSats <= 0 && _view == _View.waiting) {
      return _scaffold(_noAmountView());
    }
    if (_collecting && _view == _View.waiting) {
      return _scaffold(_collectingView());
    }
    switch (_view) {
      case _View.paid:
        return _scaffold(
          PaymentSuccessView(
              satsStr: _satsStr, arsStr: _arsStr, onBack: _finishAndBack),
          title: null,
        );
      case _View.addedToTab:
        return _scaffold(_addedToTabView(), title: null);
      case _View.waiting:
        return _scaffold(_waitingView());
    }
  }

  Widget _scaffold(Widget body, {String? title = 'Cobrar'}) => Scaffold(
        appBar: PosAppBar(
            title: title != null ? context.tr(title) : null,
            showSettings: false),
        body: PosBody(child: body),
      );

  Widget _noAmountView() => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: AppColors.error, size: 48),
          const SizedBox(height: 14),
          Text(context.tr('No se pudo generar la invoice.'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(context.tr('La orden no tiene monto.'),
              style: const TextStyle(color: AppColors.muted)),
          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
                onPressed: _goBack, child: Text(context.tr('Volver'))),
          ),
        ],
      );

  Widget _waitingView() {
    if (_invoiceError != null) return _invoiceErrorView();
    return InvoiceView(
      satsStr: _satsStr,
      arsStr: _arsStr,
      invoice: _invoice, // null → shows the loading template + QR scramble
      nfcAvailable: _nfcAvailable,
      tabEnabled: appSettings.value.tabEnabled,
      onCancel: _goBack,
      onCopy: _copyInvoice,
      onCheck: _checkEvent,
      onAddTab: _openAddToTab,
    );
  }

  /// Shown while a tapped card is being charged (LNURL-withdraw in progress).
  Widget _collectingView() => NfcChargingView(
        progress: _collectProgress,
        currentStep: _collectStepIndex,
        steps: [
          context.tr('Leyendo la tarjeta…'),
          context.tr('Solicitando el pago…'),
          context.tr('Confirmando el pago…'),
        ],
        amountLabel: '$_satsStr sats · ≈ $_arsStr ARS',
      );

  Widget _invoiceErrorView() => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: AppColors.error, size: 48),
          const SizedBox(height: 14),
          Text(context.tr('No se pudo generar la invoice.'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(_invoiceError ?? '',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted)),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                    onPressed: _goBack, child: Text(context.tr('Volver'))),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                    onPressed: _fetchInvoice,
                    child: Text(context.tr('Reintentar'))),
              ),
            ],
          ),
        ],
      );

  Widget _addedToTabView() {
    final total = _tabTotalSats ?? widget.amountSats;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.check_circle, color: AppColors.primary, size: 64),
        const SizedBox(height: 16),
        Text(context.tr('Agregado a la cuenta'),
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(_tabName ?? '',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        Text('+ $_satsStr sats ${context.tr('agregados')}',
            style: const TextStyle(color: AppColors.muted)),
        const SizedBox(height: 4),
        Text(context.tr('Total de la cuenta'),
            style: const TextStyle(color: AppColors.muted, fontSize: 13)),
        Text('${_satsOf(total)} sats',
            style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: AppColors.primary)),
        Text('≈ ${_arsOf(total)} ARS',
            style: const TextStyle(color: AppColors.muted, fontSize: 13)),
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
              onPressed: _finishAndBack, child: Text(context.tr('Volver'))),
        ),
      ],
    );
  }

  void _copyInvoice() {
    final inv = _invoice;
    if (inv == null) return;
    Clipboard.setData(ClipboardData(text: inv));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(context.tr('Invoice copiada')),
          duration: const Duration(seconds: 1)),
    );
  }

  void _addToExisting(MockTab t) {
    _poll?.cancel();
    resetOrder(); // items moved to the tab — clear the cart
    setState(() {
      _tabName = t.name;
      _tabTotalSats = t.amountSats + widget.amountSats;
      _view = _View.addedToTab;
    });
  }

  void _createTab(String name) {
    _poll?.cancel();
    resetOrder(); // items moved to the tab — clear the cart
    setState(() {
      _tabName = name;
      _tabTotalSats = widget.amountSats;
      _view = _View.addedToTab;
    });
  }

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
            Text(context.tr('Agregar a una cuenta'),
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('${context.tr('Cobrando')} $_satsStr sats',
                style: const TextStyle(color: AppColors.muted, fontSize: 13)),
            const SizedBox(height: 16),
            if (kMockTabs.isNotEmpty) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Text(context.tr('CUENTAS ABIERTAS'),
                    style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 12,
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: kMockTabs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final t = kMockTabs[i];
                    return Material(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          _addToExisting(t);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(t.name,
                                        style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w700)),
                                    Text(t.summary,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            color: AppColors.muted,
                                            fontSize: 12)),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text('${_satsOf(t.amountSats)} sats',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700)),
                                  Text('${_arsOf(t.amountSats)} ARS',
                                      style: const TextStyle(
                                          color: AppColors.muted, fontSize: 12)),
                                ],
                              ),
                              const SizedBox(width: 6),
                              const Icon(Icons.add_circle,
                                  color: AppColors.primary, size: 22),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              Row(children: [
                const Expanded(child: Divider(color: AppColors.muted)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(context.tr('o crear una nueva'),
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 12)),
                ),
                const Expanded(child: Divider(color: AppColors.muted)),
              ]),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: ctrl,
              decoration: InputDecoration(
                filled: true,
                fillColor: AppColors.surface,
                hintText: context.tr('Nombre del nuevo cliente'),
                border: const OutlineInputBorder(
                    borderSide: BorderSide.none,
                    borderRadius: BorderRadius.all(Radius.circular(12))),
              ),
              onSubmitted: (v) {
                if (v.trim().isEmpty) return;
                Navigator.of(ctx).pop();
                _createTab(v.trim());
              },
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                final name = ctrl.text.trim();
                if (name.isEmpty) return;
                Navigator.of(ctx).pop();
                _createTab(name);
              },
              child: Text(context.tr('Crear cuenta nueva')),
            ),
          ],
        ),
      ),
    );
  }
}
