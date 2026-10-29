import 'dart:async';

import 'package:flutter/material.dart' as m;
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/flow_lock.dart';
import '../../core/i18n.dart';
import '../../core/numpad.dart';
import '../../core/pin_dialog.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../core/widgets.dart';
import '../../data/lnurl/lnurl_service.dart';
import '../../domain/config/currencies.dart';
import '../../domain/config/formatter.dart';
import '../../domain/config/session.dart';
import '../cards/cards_widgets.dart' show TokenScanPage;
import 'wapu_account.dart';
import 'wapu_api.dart';
import 'wapu_destination.dart';
import 'wapu_error_text.dart';

/// Where the sale is: the customer's address, then the amount, then the order.
enum _Step { destination, amount, status }

/// What the amount is typed in: pesos to spend, or the sats the customer gets.
enum _Mode { ars, sats }

/// How long the amount rests before its price is asked for.
const _quoteDelay = Duration(milliseconds: 500);

/// The most digits the pad takes, as on the cash register's.
const _maxDigits = 12;

/// Pesos and the rate, grouped with dots like every other amount of the till.
final _pesos = NumberFormat.decimalPattern('es_AR');
final _percent = NumberFormat('0.00', 'es_AR');

/// What the customer pays when it is not what was typed: to the centavo.
final _pesosAndCents = NumberFormat.decimalPattern('es_AR')
  ..minimumFractionDigits = 2
  ..maximumFractionDigits = 2;

String _satsText(int sats) => '${formatToPreference(Currency.sat, sats)} sats';

/// Whether [a] and [b] are the same key on the same backend. A reload hands
/// back a new object each time, so the fields are what is compared.
bool _sameAccount(WapuCredentials? a, WapuCredentials? b) =>
    a?.apiKey == b?.apiKey && a?.baseUrl == b?.baseUrl;

/// The Wapu sale. It needs a signed-in POS user with a saved WapuPay key, and
/// says so when either is missing. With both, the operator scans or types the
/// customer's lightning address, and the sale goes on from there.
///
/// Free text (an address, a message that may carry one) is Material [m.Text],
/// not the app's [Text], which would uppercase it and squeeze it into one line.
class WapuScreen extends StatefulWidget {
  const WapuScreen({super.key});

  @override
  State<WapuScreen> createState() => _WapuScreenState();
}

class _WapuScreenState extends State<WapuScreen> {
  /// The text of the destination field, kept while another step is showing.
  final _destination = TextEditingController();

  /// What is saved for the signed-in POS user. Null when nothing is, and until
  /// [_loaded].
  WapuCredentials? _credentials;

  /// [_credentials] is the current POS user's, not the previous one's.
  bool _loaded = false;

  /// Reads of [_credentials] started so far: only the latest may answer.
  int _loads = 0;

  _Step _step = _Step.destination;

  /// The customer's address once it resolved, normalized: what the sale sends
  /// sats to. Set from the amount step on.
  String? _address;

  /// A lookup of the typed address is under way, so the first step waits.
  bool _checking = false;

  /// Why the address cannot be used, as Spanish source text.
  String? _error;

  /// Counts sales. Whatever is still on its way for an earlier one compares it
  /// when it lands, and is dropped.
  int _gen = 0;

  /// What the amount is typed in. A sale starts in pesos.
  _Mode _mode = _Mode.ars;

  /// The digits typed: '0' for none. Pesos in ARS mode, sats in sats mode.
  String _raw = '0';

  /// The amount to price, from [_raw]. In ARS mode [_arsCents] is the pesos
  /// times 100 and [_sats] is null, in sats mode the other way round, and both
  /// are null while nothing is typed. The order is created from the one set.
  int? _arsCents;
  int? _sats;

  /// What the backend says that amount costs. Only the reply for the amount on
  /// screen lands here, so it is never an older one's: it is the fresh quote.
  /// Null while it is being asked for, after that failed, and with no amount.
  WapuQuote? _quote;

  /// Why [_quote] is missing, when asking for it failed.
  WapuApiException? _quoteError;

  /// Waits for the operator to stop typing before the price is asked for.
  Timer? _debounce;

  /// Counts changes of the amount. A reply compares it when it lands, and is
  /// dropped if the amount moved on while it was on its way.
  int _quoteGen = 0;

  bool get _signedIn => merchantAddress.value.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    merchantAddress.addListener(_onMerchant);
    _load();
  }

  @override
  void dispose() {
    merchantAddress.removeListener(_onMerchant);
    _debounce?.cancel();
    _destination.dispose();
    super.dispose();
  }

  /// A different POS user: the sale and the key on screen are not theirs.
  void _onMerchant() {
    setState(() {
      _resetSale();
      _credentials = null;
      _loaded = false;
    });
    _load();
  }

  /// Drops the sale in progress, back to the first step with nothing typed.
  /// Call it inside [setState].
  void _resetSale() {
    _gen++;
    _destination.clear();
    _address = null;
    _error = null;
    _checking = false;
    _step = _Step.destination;
    _mode = _Mode.ars;
    _clearAmount();
  }

  Future<void> _load() async {
    final load = ++_loads;
    final credentials = await wapuAccounts.load(merchantAddress.value);
    if (!mounted || load != _loads) return;
    setState(() {
      // Another key or backend (the config changed them): a price from the old
      // one is not this one's, so none stays on screen to be confirmed.
      if (!_sameAccount(_credentials, credentials)) _clearAmount();
      _credentials = credentials;
      _loaded = true;
    });
  }

  /// The gear and Configurar: the config, behind the PIN when one is set. It
  /// can close without saying what it did (a partial save, the system back), so
  /// the key is read again whatever it returns.
  Future<void> _openConfig() async {
    if (!await confirmMiniappPin(context, action: 'Entrar')) return;
    if (!mounted) return;
    await context.push('/wapu/config');
    if (mounted) _load();
  }

  Future<void> _scan() async {
    final prompt = context.tr('Escaneá la lightning address del cliente');
    final raw = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => TokenScanPage(prompt: prompt)));
    if (raw == null || !mounted) return;
    setState(() {
      _destination.text = raw;
      _error = null;
    });
  }

  /// Checks the typed text is an address the backend takes, then that it
  /// resolves. Only then does the sale move on.
  Future<void> _continue() async {
    final text = _destination.text;
    final problem = switch (classifyDestination(text)) {
      DestinationKind.lightningAddress => null,
      DestinationKind.invoice =>
        'Eso es un invoice. Pedile al cliente su lightning address',
      DestinationKind.lnurl =>
        'Eso es un LNURL. Pedile al cliente su lightning address',
      DestinationKind.invalid => 'La lightning address no es válida',
    };
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final address = normalizeDestination(text);
    final gen = _gen;
    setState(() {
      _checking = true;
      _error = null;
    });
    String? error;
    try {
      await lnurl.validate(address);
    } on LnurlException catch (e) {
      error = e.message; // already Spanish, and says what went wrong
    } catch (_) {
      error = 'No se pudo verificar la lightning address';
    }
    if (!mounted || gen != _gen) return;
    setState(() {
      _checking = false;
      _error = error;
      if (error == null) {
        _address = address;
        _step = _Step.amount;
      }
    });
  }

  /// Forgets the amount and all that was asked for it: the clock that was
  /// running and any reply still on its way. Call it inside [setState].
  void _clearAmount() {
    _debounce?.cancel();
    _quoteGen++;
    _raw = '0';
    _arsCents = null;
    _sats = null;
    _quote = null;
    _quoteError = null;
  }

  /// Digits typed as pesos are not sats, so the other unit starts from nothing.
  void _setMode(_Mode mode) {
    if (mode == _mode) return;
    setState(() {
      _clearAmount();
      _mode = mode;
    });
  }

  // The pad edits the digits as the cash register's does (core/amount_pad.dart),
  // which cannot be used here: it yields sats and rewrites the global currency.
  void _digit(String d) {
    if (_raw == '0') {
      if (d != '00') _type(d);
    } else if (_raw.length + d.length <= _maxDigits) {
      _type(_raw + d);
    }
  }

  void _back() =>
      _type(_raw.length <= 1 ? '0' : _raw.substring(0, _raw.length - 1));

  /// The digits became [raw]. The price on screen is of the old amount, so it
  /// goes, and the new one is asked for once the operator pauses.
  void _type(String raw) {
    if (raw == _raw) return;
    final n = int.parse(raw);
    setState(() {
      _clearAmount();
      _raw = raw;
      if (n > 0) {
        if (_mode == _Mode.ars) {
          _arsCents = n * 100;
        } else {
          _sats = n;
        }
      }
    });
    if (n > 0) {
      final credentials = _credentials!; // the pad only shows with a key
      _debounce = Timer(_quoteDelay, () => _fetchQuote(credentials));
    }
  }

  /// Asks the backend what the amount on screen costs.
  Future<void> _fetchQuote(WapuCredentials credentials) async {
    final gen = _quoteGen;
    WapuQuote? quote;
    WapuApiException? error;
    try {
      quote = await wapuApiFor(credentials.baseUrl, credentials.apiKey)
          .quote(arsCents: _arsCents, sats: _sats);
    } on WapuApiException catch (e) {
      error = e;
    } catch (_) {
      error = const WapuApiException(''); // the generic copy, with no detail
    }
    if (!mounted || gen != _quoteGen) return;
    setState(() {
      _quote = quote;
      _quoteError = error;
    });
  }

  bool _belowMinimum(WapuQuote q) => q.amountArsCents < q.minAmountArsCents;

  /// The quote is the fresh one, the backend can fill the order, and the amount
  /// clears the minimum.
  bool get _canConfirm {
    final q = _quote;
    return q != null && q.liquidityOk && !_belowMinimum(q);
  }

  /// Creates the order. The button only gates until then.
  void _confirm() {}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PosAppBar(
        title: 'Wapu',
        lockFlow: '/wapu',
        showSettings: false, // its gear has no PIN gate
        showSync: false,
        showInvoiceDebug: false,
        actions: [
          // Nobody to keep a key for, and out of reach while the till is locked.
          if (_signedIn)
            ValueListenableBuilder<String?>(
              valueListenable: lockedFlow,
              builder: (context, locked, _) => locked != null
                  ? const SizedBox.shrink()
                  : IconButton(
                      key: const Key('wapu-config'),
                      tooltip:
                          context.tr('Configuración de Wapu').toUpperCase(),
                      icon: const Icon(Icons.settings_outlined, size: 26),
                      onPressed: _openConfig,
                    ),
            ),
        ],
      ),
      body: PosBody(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    if (!_signedIn) {
      return _notice(
          context, 'Ingresá con la dirección del comercio para usar Wapu');
    }
    if (!_loaded) return const SizedBox.shrink();
    if (_credentials == null) {
      return _notice(
        context,
        'Configurá tu API key de Wapu',
        action: FilledButton(
          key: const Key('wapu-setup'),
          onPressed: _openConfig,
          child: Text(context.tr('Configurar')),
        ),
      );
    }
    return switch (_step) {
      _Step.destination => _destinationStep(context),
      _Step.amount => _amountStep(context),
      _Step.status => const SizedBox(),
    };
  }

  /// A line of the till's own copy, centered, with the button that answers it.
  Widget _notice(BuildContext context, String copy, {Widget? action}) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            context.tr(copy),
            textAlign: TextAlign.center,
            softWrap: true,
            style: const TextStyle(color: AppColors.muted),
          ),
          if (action != null) ...[const SizedBox(height: 24), action],
        ],
      ),
    );
  }

  Widget _destinationStep(BuildContext context) {
    final error = _error;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        const SizedBox(height: 16),
        TextField(
          key: const Key('wapu-destination'),
          controller: _destination,
          enabled: !_checking,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.done,
          autocorrect: false,
          enableSuggestions: false,
          onSubmitted: (_) => _continue(),
          decoration: InputDecoration(
            labelText: context.tr('Lightning address del cliente'),
            hintText: context.tr('nombre@dominio.com'),
            floatingLabelBehavior: FloatingLabelBehavior.always,
            filled: true,
            fillColor: AppColors.surface,
            border: const UnderlineInputBorder(
              borderSide: BorderSide.none,
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: m.Text(
              context.tr(error),
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.error),
            ),
          ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: _checking ? null : _scan,
          icon: const Icon(Icons.qr_code_scanner),
          label: Text(context.tr('Escanear QR')),
        ),
        const SizedBox(height: 12),
        FilledButton(
          key: const Key('wapu-continue'),
          onPressed: _checking ? null : _continue,
          child: _checking
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 3),
                )
              : Text(context.tr('Continuar')),
        ),
      ],
    );
  }

  /// The address, the unit, the amount with its price, and the pad. Only the
  /// middle scrolls: the pad and Confirmar stay put on a short screen.
  Widget _amountStep(BuildContext context) {
    final quote = _quote;
    final error = _quoteError;
    final typed = int.parse(_raw);
    return Column(
      key: const Key('wapu-amount'),
      children: [
        Row(
          children: [
            Expanded(
              child: m.Text(
                _address ?? '',
                softWrap: true,
                style: const TextStyle(color: AppColors.muted),
              ),
            ),
            IconButton(
              tooltip: context.tr('Cambiar dirección').toUpperCase(),
              icon: const Icon(Icons.edit_outlined),
              // One step back, not a new sale: the field keeps what was typed.
              onPressed: () => setState(() => _step = _Step.destination),
            ),
          ],
        ),
        SegmentedButton<_Mode>(
          style: SegmentedButton.styleFrom(
            backgroundColor: AppColors.surface,
            selectedBackgroundColor: AppColors.primary,
            selectedForegroundColor: Colors.black,
          ),
          segments: const [
            ButtonSegment(
              value: _Mode.ars,
              label: Text('ARS', key: Key('wapu-mode-ars')),
            ),
            ButtonSegment(
              value: _Mode.sats,
              label: Text('SATS', key: Key('wapu-mode-sats')),
            ),
          ],
          selected: {_mode},
          showSelectedIcon: false,
          onSelectionChanged: (s) => _setMode(s.first),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: m.Text(
                    _mode == _Mode.ars
                        ? '\$ ${_pesos.format(typed)}'
                        : _satsText(typed),
                    style: const TextStyle(
                        fontSize: 40, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: 8),
                if (quote != null)
                  ..._quoteLines(context, quote)
                else if (error != null)
                  WapuErrorText(error)
                else if (typed > 0)
                  const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 3),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Numpad(onDigit: _digit, onBackspace: _back),
        const SizedBox(height: 8),
        FilledButton(
          key: const Key('wapu-confirm'),
          onPressed: _canConfirm ? _confirm : null,
          child: Text(context.tr('Confirmar')),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  /// What stands in the way of the order, if anything, then what the customer
  /// gets for the amount. The warnings come first: on a short screen the lines
  /// scroll, and a Confirmar that is off must say why where it can be seen. In
  /// sats mode the pesos are not what was typed, so what the customer pays leads
  /// the lines: the operator reads it before confirming.
  List<Widget> _quoteLines(BuildContext context, WapuQuote q) {
    final rate = '\$ ${_pesos.format(q.arsPerBtc.round())}';
    final minimum = '\$ ${_pesos.format(q.minAmountArsCents ~/ 100)}';
    return [
      if (_belowMinimum(q))
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: m.Text(
            '${context.tr('El mínimo es ')}$minimum',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.error),
          ),
        ),
      // The copy of the 409 that an order would meet if it were tried.
      if (!q.liquidityOk)
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: WapuErrorText(WapuApiException('', statusCode: 409)),
        ),
      if (_mode == _Mode.sats)
        _line(context, 'El cliente paga',
            '\$ ${_pesosAndCents.format(q.amountArsCents / 100)}'),
      _line(context, 'El cliente recibe', _satsText(q.amountOut)),
      _line(context, 'Tipo de cambio', '$rate${context.tr(' por BTC')}'),
      _line(context, 'Comisión incluida', '${_percent.format(q.feePercent)}%'),
      _line(context, 'Fee de red estimado', _satsText(q.networkFeeOut)),
    ];
  }

  /// A label and its value, apart on one line. When they do not fit side by
  /// side (a long rate, a large text size) the value drops to the next line.
  Widget _line(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        children: [
          m.Text(
            context.tr(label),
            style: const TextStyle(color: AppColors.muted),
          ),
          m.Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
