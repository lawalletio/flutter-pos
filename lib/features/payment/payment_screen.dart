import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/lnurl/lnurl_service.dart';
import '../../data/mock/mock_data.dart';
import '../../data/pricing/pricing_service.dart';
import '../../domain/config/currencies.dart';
import '../../domain/config/formatter.dart';
import '../../domain/config/session.dart';
import '../../domain/config/settings_state.dart';
import '../../domain/order/order_reset.dart';
import '../../platform/nfc_channel.dart';
import '../../platform/printer_channel.dart';
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

enum _View { waiting, paid, checking, addedToTab }

class _PaymentScreenState extends State<PaymentScreen> {
  late _View _view = widget.initiallyPaid ? _View.paid : _View.waiting;
  String? _tabName;
  int? _tabTotalSats;

  // Real invoice state.
  String? _invoice; // bolt11
  String? _verifyUrl; // LUD-21
  String? _invoiceError;
  bool _loadingInvoice = false;
  bool _printed = false;
  bool _collecting = false; // pulling payment from a tapped card
  bool _nfcAvailable = false;
  StreamSubscription<String>? _nfcSub;
  Timer? _poll;

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
  }

  /// Auto-print the receipt on the ZCS printer. No-op where there's no printer
  /// (e.g. web preview) — the channel returns gracefully.
  Future<void> _printReceipt() async {
    if (_printed) return;
    _printed = true;
    final ars = pricing.satsToFiat(widget.amountSats, Currency.ars);
    await PrinterChannel.printOrder({
      'items': const <Map<String, dynamic>>[],
      'currency': 'ARS',
      'total': ars != null ? formatToPreference(Currency.ars, ars) : '-',
      'totalSats': formatToPreference(Currency.sat, widget.amountSats),
      'message': 'Gracias por su pago',
    });
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

  /// A card was tapped: show progress while pulling the payment (LNURL-withdraw).
  Future<void> _collectFromCard(String cardUrl) async {
    final inv = _invoice;
    if (inv == null) return;
    setState(() => _collecting = true);
    try {
      await lnurl.payWithCard(cardUrl, inv);
      // Submitted — confirm settlement (a few seconds), else leave it to polling.
      final url = _verifyUrl;
      var settled = false;
      if (url != null) {
        for (var i = 0; i < 12 && mounted; i++) {
          if (await lnurl.checkSettled(url)) {
            settled = true;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 800));
        }
      }
      if (!mounted) return;
      if (settled) {
        _markPaid();
      } else {
        setState(() => _collecting = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Pago enviado, esperando confirmación…')));
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
      _loadingInvoice = true;
      _invoiceError = null;
    });
    try {
      final inv =
          await lnurl.requestInvoice(merchantAddress.value, widget.amountSats);
      if (!mounted) return;
      setState(() {
        _invoice = inv.pr;
        _verifyUrl = inv.verify;
        _loadingInvoice = false;
      });
      _startPolling();
      _startAutoNfc(); // arm the card reader while pending
    } on LnurlException catch (e) {
      if (!mounted) return;
      setState(() {
        _invoiceError = e.message;
        _loadingInvoice = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _invoiceError = 'No se pudo generar la invoice';
        _loadingInvoice = false;
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
    if (_loadingInvoice) return _generatingView();
    if (_invoiceError != null) return _invoiceErrorView();
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
        _qrCard(),
        const SizedBox(height: 6),
        TextButton.icon(
          onPressed: _copyInvoice,
          icon: const Icon(Icons.copy, size: 15),
          label: const Text('Copiar invoice'),
        ),
        const SizedBox(height: 8),
        if (_nfcAvailable) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.contactless_outlined,
                  size: 18, color: AppColors.primary),
              SizedBox(width: 8),
              Text('Acercá la tarjeta para pagar',
                  style: TextStyle(color: AppColors.primary)),
            ],
          ),
          const SizedBox(height: 12),
        ],
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _goBack,
            child: const Text('Cancelar'),
          ),
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
        TextButton(
          onPressed: _markPaid,
          child: const Text('▶ Simular pago recibido (demo)'),
        ),
      ],
    );
  }

  /// Big invoice QR — the white card spans the screen width minus 25px on each
  /// side. OverflowBox lets it exceed the surrounding PosBody padding, staying
  /// centered so the margins are exactly 25px.
  Widget _qrCard() {
    final screenW = MediaQuery.of(context).size.width;
    final card = screenW - 50;
    return SizedBox(
      height: card,
      child: OverflowBox(
        maxWidth: screenW,
        child: GestureDetector(
          onLongPress: _copyInvoice,
          child: Container(
            width: card,
            height: card,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: QrImageView(
              data: (_invoice ?? '').toUpperCase(),
              version: QrVersions.auto,
              padding: EdgeInsets.zero,
            ),
          ),
        ),
      ),
    );
  }

  /// Shown while a tapped card is being charged (LNURL-withdraw in progress).
  Widget _collectingView() => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
              width: 56,
              height: 56,
              child: CircularProgressIndicator(strokeWidth: 4)),
          const SizedBox(height: 24),
          const Icon(Icons.contactless, color: AppColors.primary, size: 32),
          const SizedBox(height: 12),
          const Text('Cobrando de la tarjeta…',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text('$_satsStr sats · ≈ $_arsStr ARS',
              style: const TextStyle(color: AppColors.muted)),
          const SizedBox(height: 10),
          const Text('No retires la tarjeta',
              style: TextStyle(color: AppColors.muted, fontSize: 13)),
        ],
      );

  Widget _generatingView() => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          CircularProgressIndicator(),
          SizedBox(height: 20),
          Text('Generando invoice…',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          SizedBox(height: 6),
          Text('Resolviendo la Lightning Address…',
              style: TextStyle(color: AppColors.muted)),
        ],
      );

  Widget _invoiceErrorView() => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: AppColors.error, size: 48),
          const SizedBox(height: 14),
          const Text('No se pudo generar la invoice.',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(_invoiceError ?? '',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted)),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                    onPressed: _goBack, child: const Text('Volver')),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                    onPressed: _fetchInvoice, child: const Text('Reintentar')),
              ),
            ],
          ),
        ],
      );

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
                  onPressed: () async {
                    final url = _verifyUrl;
                    if (url != null && await lnurl.checkSettled(url)) {
                      if (mounted) _markPaid();
                    } else if (mounted) {
                      setState(() => _view = _View.waiting);
                    }
                  },
                  child: const Text('Check event'),
                ),
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
        const Text('Agregado a la cuenta',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(_tabName ?? '',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        Text('+ $_satsStr sats agregados',
            style: const TextStyle(color: AppColors.muted)),
        const SizedBox(height: 4),
        const Text('Total de la cuenta',
            style: TextStyle(color: AppColors.muted, fontSize: 13)),
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
              onPressed: _finishAndBack, child: const Text('Volver')),
        ),
      ],
    );
  }

  void _copyInvoice() {
    final inv = _invoice;
    if (inv == null) return;
    Clipboard.setData(ClipboardData(text: inv));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Invoice copiada'), duration: Duration(seconds: 1)),
    );
  }

  void _addToExisting(MockTab t) {
    _poll?.cancel();
    setState(() {
      _tabName = t.name;
      _tabTotalSats = t.amountSats + widget.amountSats;
      _view = _View.addedToTab;
    });
  }

  void _createTab(String name) {
    _poll?.cancel();
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
            const Text('Agregar a una cuenta',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('Cobrando $_satsStr sats',
                style: const TextStyle(color: AppColors.muted, fontSize: 13)),
            const SizedBox(height: 16),
            if (kMockTabs.isNotEmpty) ...[
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('CUENTAS ABIERTAS',
                    style: TextStyle(
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
              Row(children: const [
                Expanded(child: Divider(color: AppColors.muted)),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10),
                  child: Text('o crear una nueva',
                      style: TextStyle(color: AppColors.muted, fontSize: 12)),
                ),
                Expanded(child: Divider(color: AppColors.muted)),
              ]),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                filled: true,
                fillColor: AppColors.surface,
                hintText: 'Nombre del nuevo cliente',
                border: OutlineInputBorder(
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
              child: const Text('Crear cuenta nueva'),
            ),
          ],
        ),
      ),
    );
  }
}
