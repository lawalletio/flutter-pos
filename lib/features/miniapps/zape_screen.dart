import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n.dart';
import '../../core/numpad.dart';
import '../../core/pin_dialog.dart';
import '../../core/print_error.dart';
import '../../core/sounds.dart';
import '../../core/theme.dart';
import '../../data/lnurl/lnurl_service.dart';
import '../../data/nostr/profile_service.dart';
import '../../data/nostr/relay_pool.dart';
import '../../data/pricing/pricing_service.dart';
import '../../domain/config/currencies.dart';
import '../../domain/config/formatter.dart';
import '../../domain/config/session.dart';
import '../../domain/config/settings_state.dart';
import '../../platform/printer_channel.dart';
import '../payment/invoice_view.dart';

/// Tip amounts offered on the first screen.
const zapePresets = [2100, 5000, 10000, 21000];

/// Strip length for a tip: 21000 sats prints the longest strip (40 points,
/// 1 point = 1.7 cm) and the "e" holds as long as the printer runs, so a
/// bigger tip prints and sounds longer.
// ponytail: linear and capped at 40, bigger custom tips all max out.
int zapePoints(int sats) => (sats * 40 / 21000).round().clamp(1, 40);

/// Kiosk miniapp for tips: pick an amount, pay the QR to the logged Lightning
/// Address, and a ZAPE strip prints with a sound as long as the tip is big.
///
/// No back, settings, relay or debug buttons. The only way out is the X,
/// which asks for the miniapp PIN.
class ZapeScreen extends StatefulWidget {
  const ZapeScreen({super.key});

  @override
  State<ZapeScreen> createState() => _ZapeScreenState();
}

enum _Step { pick, custom, invoice, printing }

class _ZapeScreenState extends State<ZapeScreen> {
  var _step = _Step.pick;
  var _raw = '0';
  var _sats = 0;
  String? _invoice;
  String? _verifyUrl;
  String? _error;
  Timer? _poll;
  ZapWatcher? _zap;

  /// Bumped per invoice, so a late reply or a late paid signal from an
  /// abandoned invoice can't touch the current one.
  var _gen = 0;

  @override
  void initState() {
    super.initState();
    pricing.ensureLoaded();
  }

  @override
  void dispose() {
    _stopWatching();
    super.dispose();
  }

  void _stopWatching() {
    _poll?.cancel();
    _poll = null;
    _zap?.dispose();
    _zap = null;
  }

  void _reset() {
    _stopWatching();
    _gen++;
    setState(() {
      _step = _Step.pick;
      _raw = '0';
      _invoice = null;
      _verifyUrl = null;
      _error = null;
    });
  }

  Future<void> _charge(int sats) async {
    final gen = ++_gen;
    setState(() {
      _sats = sats;
      _step = _Step.invoice;
      _invoice = null;
      _error = null;
    });
    try {
      final identity = await nostrProfile.resolveNip05(merchantAddress.value);
      if (!mounted || gen != _gen) return;
      final inv = await lnurl.requestInvoice(
        merchantAddress.value,
        sats,
        relays: appSettings.value.relays,
        recipientPubkey: identity?.pubkey,
      );
      if (!mounted || gen != _gen) return;
      setState(() {
        _invoice = inv.pr;
        _verifyUrl = inv.verify;
      });
      final url = inv.verify;
      if (url != null) {
        _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
          try {
            if (await lnurl.checkSettled(url)) _paid(gen);
          } catch (_) {/* keep polling */}
        });
      }
      if (inv.zapEnabled) {
        _zap = ZapWatcher(
          relays: inv.zapRelays,
          zapperPubkey: inv.zapPubkey!,
          invoice: inv.pr,
          orderId: inv.zapOrderId,
          onPaid: () => _paid(gen),
        )..start();
      }
    } on LnurlException catch (e) {
      if (mounted && gen == _gen) setState(() => _error = e.message);
    } catch (_) {
      if (mounted && gen == _gen) {
        setState(() => _error = 'No se pudo generar la invoice');
      }
    }
  }

  Future<void> _paid(int gen) async {
    if (!mounted || gen != _gen || _step != _Step.invoice) return;
    _stopWatching();
    setState(() => _step = _Step.printing);
    final points = zapePoints(_sats);
    await printOrAskToContinue(context, print: () async {
      AppSounds.startZape();
      final result = await PrinterChannel.printZape(points);
      AppSounds.stopZape();
      return result;
    });
    if (mounted && gen == _gen) _reset();
  }

  Future<void> _check() async {
    final url = _verifyUrl;
    if (url == null) return;
    try {
      if (await lnurl.checkSettled(url)) _paid(_gen);
    } catch (_) {}
  }

  String _satsStr(int sats) => formatToPreference(Currency.sat, sats);
  String _arsStr(int sats) => formatToPreference(
      Currency.ars, pricing.satsToFiat(sats, Currency.ars) ?? 0);

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: AppColors.background,
          automaticallyImplyLeading: false,
          toolbarHeight: 72,
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: IconButton(
                key: const Key('miniapp-close'),
                icon: const Icon(Icons.close, size: 30),
                onPressed: () => _close(context),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: switch (_step) {
              _Step.pick => _pick(),
              _Step.custom => _custom(),
              _Step.invoice => _error != null ? _failed() : _qr(),
              _Step.printing => _printing(),
            },
          ),
        ),
      ),
    );
  }

  Widget _pick() {
    Widget amount(int sats) => SizedBox(
          height: 80,
          child: FilledButton(
            key: Key('zape-$sats'),
            style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20))),
            onPressed: () => _charge(sats),
            child: Text(_satsStr(sats),
                style:
                    const TextStyle(fontFamily: 'ClimateCrisis', fontSize: 30)),
          ),
        );
    return Center(
        child: SingleChildScrollView(
            child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('ZAPE',
            textAlign: TextAlign.center,
            style: TextStyle(fontFamily: 'ClimateCrisis', fontSize: 56)),
        const SizedBox(height: 8),
        Text(context.tr('Elegí tu propina en sats'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.muted, fontSize: 18)),
        const SizedBox(height: 28),
        for (final sats in zapePresets)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: amount(sats),
          ),
        SizedBox(
          height: 72,
          child: OutlinedButton(
            key: const Key('zape-custom'),
            onPressed: () => setState(() => _step = _Step.custom),
            child: Text(context.tr('Monto personalizado'),
                style: const TextStyle(fontSize: 20)),
          ),
        ),
      ],
    )));
  }

  Widget _custom() {
    final sats = int.tryParse(_raw) ?? 0;
    return Column(
      children: [
        const Spacer(),
        Text('${_satsStr(sats)} sats',
            style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text('≈ ${_arsStr(sats)} ARS',
            style: const TextStyle(color: AppColors.muted, fontSize: 16)),
        const Spacer(),
        Numpad(
          onDigit: (d) => setState(() {
            if (_raw == '0') {
              _raw = d == '00' ? '0' : d;
            } else if (_raw.length + d.length <= 9) {
              _raw += d;
            }
          }),
          onBackspace: () => setState(() => _raw =
              _raw.length <= 1 ? '0' : _raw.substring(0, _raw.length - 1)),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: OutlinedButton(
                onPressed: _reset, child: Text(context.tr('Cancelar'))),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton(
              key: const Key('zape-custom-go'),
              onPressed: sats > 0 ? () => _charge(sats) : null,
              child: Text(context.tr('Siguiente')),
            ),
          ),
        ]),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _qr() => InvoiceView(
        satsStr: _satsStr(_sats),
        arsStr: _arsStr(_sats),
        invoice: _invoice,
        nfcAvailable: false,
        tabEnabled: false,
        onCancel: _reset,
        onCopy: () => Clipboard.setData(ClipboardData(text: _invoice ?? '')),
        onCheck: _check,
        onAddTab: () {},
      );

  Widget _failed() => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(context.tr(_error!),
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.error, fontSize: 18)),
          const SizedBox(height: 20),
          OutlinedButton(onPressed: _reset, child: Text(context.tr('Volver'))),
        ],
      );

  Widget _printing() => const Center(
        child: Text('ZAPEEE',
            style: TextStyle(fontFamily: 'ClimateCrisis', fontSize: 56)),
      );

  Future<void> _close(BuildContext context) async {
    if (await confirmMiniappPin(context, action: 'Salir') && context.mounted) {
      context.go('/');
    }
  }
}
