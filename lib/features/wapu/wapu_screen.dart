import 'dart:async';

import 'package:flutter/material.dart' as m;
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/flow_lock.dart';
import '../../core/i18n.dart';
import '../../core/numpad.dart';
import '../../core/pin_dialog.dart';
import '../../core/sounds.dart';
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
import 'wapu_status_view.dart';

/// Where the sale is: the customer's address, then the amount, then the order.
enum _Step { destination, amount, status }

/// What the amount is typed in: pesos to spend, or the sats the customer gets.
enum _Mode { ars, sats }

/// How long the amount rests before its price is asked for.
const _quoteDelay = Duration(milliseconds: 500);

/// The most digits the pad takes, as on the cash register's.
const _maxDigits = 12;

/// How often an order that the backend still watches is read again.
const _pollEvery = Duration(seconds: 10);

/// How often an order whose view moves with the clock repaints.
const _tickEvery = Duration(seconds: 1);

/// Pesos and the rate, grouped with dots like every other amount of the till.
final _pesos = NumberFormat.decimalPattern('es_AR');
final _percent = NumberFormat('0.00', 'es_AR');

String _satsText(int sats) => '${formatToPreference(Currency.sat, sats)} sats';

/// What a call answered, or why it did not: exactly one of the two is set.
typedef _Answer<T> = ({T? reply, WapuApiException? error});

/// [wapuCall] as a value: the caller checks that the sale is still the one the
/// call was for before it looks at either.
Future<_Answer<T>> _answer<T>(Future<T> Function() call) async {
  try {
    return (reply: await wapuCall(call), error: null);
  } on WapuApiException catch (e) {
    return (reply: null, error: e);
  }
}

/// Whether the view of [o] changes with the clock at [now]: the countdown of an
/// order that waits for the transfer, and the window of a created one, which
/// closes into "Orden vencida" with no news from the backend.
bool _ticks(WapuOrder o, DateTime now) =>
    o.status == 'FUNDING_ISSUED' ||
    (o.status == 'CREATED' && (o.expiresAt?.isAfter(now) ?? false));

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

  /// The client for [_credentials], so the quote, the order and its polls share
  /// one connection. It is built when [_load] swaps the account, and null with
  /// no key. The old one is not closed: a new one comes only with a new key.
  WapuApi? _api;

  /// [_credentials] is the current POS user's, not the previous one's.
  bool _loaded = false;

  /// Reads of [_credentials] started so far: only the latest may answer.
  int _loads = 0;

  _Step _step = _Step.destination;

  /// The customer's address once it resolved, normalized: what the sale sends
  /// sats to. Set from the amount step on.
  String? _address;

  /// A lookup of the typed address, or of an order to resume, is under way, so
  /// the first step waits.
  bool _checking = false;

  /// Why the address cannot be used, or the order of the History could not be
  /// opened, as Spanish source text.
  String? _error;

  /// Counts sales. Whatever is still on its way for an earlier one compares it
  /// when it lands, and is dropped.
  int _gen = 0;

  /// The order of the status step, as the backend last said it. The amounts
  /// there are read from it and never from [_quote]: funding can raise the
  /// pesos by up to a peso's worth of cents, and that is what the customer
  /// pays.
  WapuOrder? _order;

  /// A create or a funding is under way, so no second one may start.
  bool _busy = false;

  /// The key is being read again after the config closed, and the one on
  /// screen may not be the one the config left.
  bool _reloading = false;

  /// An order is being read again, so the next tick leaves it be.
  bool _reading = false;

  /// The question of Nueva venta is on screen, or on its way: asking it again
  /// does nothing, so there is never one dialog under another.
  bool _asking = false;

  /// Why the order could not be created. The sale stays on the amount step.
  WapuApiException? _createError;

  /// Why the order on the status step could not be funded or read again. The
  /// order stays on screen with what it showed, bank details included.
  WapuApiException? _orderError;

  /// Reads the order again while the backend still watches it.
  Timer? _poller;

  /// Repaints what moves with the clock: the countdown of the order that waits
  /// for the transfer, and the window of one that was only created.
  Timer? _ticker;

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

  /// There is a key to sell with, so there is a sale to start over.
  bool get _inSale => _signedIn && _loaded && _credentials != null;

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
    _stopClocks();
    _destination.dispose();
    super.dispose();
  }

  /// A different POS user: the sale and the key on screen are not theirs.
  void _onMerchant() {
    setState(() {
      _resetSale();
      _credentials = null;
      _api = null;
      _loaded = false;
    });
    _load();
  }

  /// Drops the sale in progress, back to the first step with nothing typed: the
  /// amount, its price and the order are gone, the clocks of the order stop,
  /// and whatever is still on its way for it is dropped when it lands. Call it
  /// inside [setState].
  void _resetSale() {
    _gen++;
    _stopClocks();
    _order = null;
    _orderError = null;
    _busy = false;
    _reading = false;
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
      if (!_sameAccount(_credentials, credentials)) {
        // The key is gone (forgotten in the config), or another key or backend
        // took its place: the sale on screen is the old account's. Its order
        // would be read with the new key and never found, or funded on the
        // wrong account, and a price from the old backend is not this one's.
        // The order is not lost: its account's History has it.
        _resetSale();
        _api = credentials == null
            ? null
            : wapuApiFor(credentials.baseUrl, credentials.apiKey);
      }
      _credentials = credentials;
      _loaded = true;
      _reloading = false;
    });
  }

  /// The gear and Configurar: the config, behind the PIN when one is set. It
  /// can close without saying what it did (a partial save, the system back), so
  /// the key is read again whatever it returns. Until it is, Confirmar waits.
  Future<void> _openConfig() async {
    if (_busy) return;
    if (!await confirmMiniappPin(context, action: 'Entrar')) return;
    if (!mounted) return;
    await context.push('/wapu/config');
    if (!mounted) return;
    setState(() => _reloading = true);
    _load();
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
  /// running, any reply still on its way, and why an order for it could not be
  /// created. Call it inside [setState].
  void _clearAmount() {
    _debounce?.cancel();
    _quoteGen++;
    _raw = '0';
    _arsCents = null;
    _sats = null;
    _quote = null;
    _quoteError = null;
    _createError = null;
  }

  /// Digits typed as pesos are not sats, so the other unit starts from nothing.
  /// Not while an order is being created for the amount on screen.
  void _setMode(_Mode mode) {
    if (mode == _mode || _busy) return;
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
  /// goes, and the new one is asked for once the operator pauses. Not while an
  /// order is being created for the amount on screen: it is not typed over.
  void _type(String raw) {
    if (raw == _raw || _busy) return;
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
      final api = _api!; // the pad only shows with a key
      _debounce = Timer(_quoteDelay, () => _fetchQuote(api));
    }
  }

  /// Asks the backend what the amount on screen costs.
  Future<void> _fetchQuote(WapuApi api) async {
    final gen = _quoteGen;
    final answer =
        await _answer(() => api.quote(arsCents: _arsCents, sats: _sats));
    if (!mounted || gen != _quoteGen) return;
    setState(() {
      _quote = answer.reply;
      _quoteError = answer.error;
    });
  }

  bool _belowMinimum(WapuQuote q) => q.amountArsCents < q.minAmountArsCents;

  /// The quote is the fresh one, the backend can fill the order, the amount
  /// clears the minimum, and nothing else is being created or settled: not an
  /// order of this sale, and not the key the order would be made with.
  bool get _canConfirm {
    final q = _quote;
    return !_busy &&
        !_reloading &&
        q != null &&
        q.liquidityOk &&
        !_belowMinimum(q);
  }

  /// Creates the order for the amount on screen, then asks for its bank
  /// details: one tap does both. A create is not idempotent, so it is made
  /// once. When it fails the sale stays on the amount, and trying again is for
  /// the operator to decide.
  Future<void> _confirm() async {
    final api = _api;
    final address = _address;
    // The button is off then, but a second tap can get here before it is
    // rebuilt.
    if (!_canConfirm || api == null || address == null) return;
    final ars = _arsCents;
    final sats = _sats;
    final gen = ++_gen;
    setState(() {
      _busy = true;
      _createError = null;
    });
    final created = await _answer(
        () => api.createOrder(address: address, arsCents: ars, sats: sats));
    if (!mounted || gen != _gen) return;
    final order = created.reply;
    if (order == null) {
      setState(() {
        _busy = false;
        _createError = created.error;
      });
      return;
    }
    setState(() {
      // From here the amounts are the order's, not the price that was quoted.
      _clearAmount();
      _order = order;
      _step = _Step.status;
    });
    await _fund(api, order.id, gen);
  }

  /// Asks [api] for the bank details of the order [id] of the sale [gen], then
  /// follows the order. Repeating it is safe: the backend answers with the same
  /// order.
  Future<void> _fund(WapuApi api, String id, int gen) async {
    final funded = await _answer(() => api.fund(id));
    if (!mounted || gen != _gen) return;
    setState(() {
      _busy = false;
      _order = funded.reply ?? _order;
      _orderError = funded.error;
    });
    _follow();
  }

  /// The button of an order that was created and has no bank details yet.
  void _requestFunding() {
    final api = _api;
    final order = _order;
    if (_busy || api == null || order == null) return;
    setState(() {
      _busy = true;
      _orderError = null;
    });
    _fund(api, order.id, _gen);
  }

  /// Starts or stops what the order on screen needs, after it changed: a read
  /// every [_pollEvery] while the backend still watches it, and a repaint every
  /// [_tickEvery] while its view moves with the clock (see [_ticks]).
  void _follow() {
    final order = _order;
    if (order != null && order.watchPending) {
      _poller ??= Timer.periodic(_pollEvery, (_) => _readOrder());
    } else {
      _poller?.cancel();
      _poller = null;
    }
    if (order != null && _ticks(order, DateTime.now())) {
      _ticker ??= Timer.periodic(_tickEvery, (_) {
        // First: it stops the clock once the window closed, and the repaint
        // after it is of the order as it stands then.
        _follow();
        setState(() {});
      });
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  void _stopClocks() {
    _poller?.cancel();
    _ticker?.cancel();
    _poller = _ticker = null;
  }

  /// Reads the order on screen again. An answer for a sale that was left
  /// meanwhile is dropped. A failure keeps the order as it was, with the reason
  /// above it, and the next tick tries again: it never takes the bank details
  /// off the screen while the customer may be using them.
  Future<void> _readOrder() async {
    final order = _order;
    final api = _api;
    // A read that is still out is not overlapped: its answer could land after
    // a newer one and put an older state on screen.
    if (order == null || api == null || _reading) return;
    final gen = _gen;
    _reading = true;
    final read = await _answer(() => api.order(order.id));
    if (!mounted || gen != _gen) return;
    final done =
        read.reply?.status == 'COMPLETED' && _order?.status != 'COMPLETED';
    setState(() {
      _reading = false;
      _order = read.reply ?? _order;
      _orderError = read.error;
    });
    _follow();
    if (done) AppSounds.play(AppSound.paid);
  }

  /// Nueva venta, from the app bar or from the button of a finished order. The
  /// order on screen is let go: it expires on its own, and the History has it.
  /// One that waits for the customer's transfer asks first. Not while an order
  /// is being created or funded: the reply would be dropped, and the order left
  /// open and never funded.
  Future<void> _newSale() async {
    if (_asking || _busy) return;
    if (_order?.status == 'FUNDING_ISSUED') {
      final gen = _gen;
      var confirmed = false;
      _asking = true;
      try {
        confirmed = await _askNewSale() ?? false;
      } finally {
        _asking = false;
      }
      // The poll goes on under the question: the customer may have paid, or the
      // till changed hands, while it was up. What was asked about is then not
      // what is on screen, and the answer must not reset it.
      if (!confirmed ||
          !mounted ||
          gen != _gen ||
          _order?.status != 'FUNDING_ISSUED') {
        return;
      }
    }
    setState(_resetSale);
  }

  /// Whether the operator lets the order that waits for the transfer go. Null
  /// when the question was dismissed.
  Future<bool?> _askNewSale() => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text(ctx.tr('Nueva venta')),
          content: m.Text(
            ctx.tr('La orden queda abierta hasta que venza. '
                'La podés retomar desde el Historial.'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(ctx.tr('Cancelar')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(ctx.tr('Nueva venta')),
            ),
          ],
        ),
      );

  /// The History, and the order it hands back, if one was chosen. The sale
  /// stays as it was when it is left with none. Not while an order is being
  /// created or funded, as Nueva venta.
  Future<void> _openHistory() async {
    if (_busy) return;
    final id = await context.push<String>('/wapu/historial');
    if (id != null && mounted) _resume(id);
  }

  /// Opens [orderId], an order of the History, on the status step and follows
  /// it as it does an order just created, without the paid cue: nothing was
  /// paid just now. The sale on screen is let go as by Nueva venta, with no
  /// question asked, and the first step waits while the order is read. If it
  /// cannot be read, the first step says why. Nothing happens without a key.
  Future<void> _resume(String orderId) async {
    final api = _api;
    if (api == null) return;
    setState(() {
      _resetSale();
      _checking = true;
    });
    final gen = _gen;
    final read = await _answer(() => api.order(orderId));
    if (!mounted || gen != _gen) return;
    final order = read.reply;
    setState(() {
      _checking = false;
      if (order == null) {
        _error = wapuErrorKey(read.error!);
      } else {
        _order = order;
        _step = _Step.status;
      }
    });
    _follow();
  }

  @override
  Widget build(BuildContext context) {
    // While an order is created or funded the sale is not left, by the system
    // back or by the app bar's: its screen would be gone when the reply lands,
    // and an order made upstream would be lost, to be made again by a retry.
    // The app bar's back pops without asking the PopScope, so it is a no-op
    // then, rather than hidden: that would also hold the till's unlock.
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: PosAppBar(
          title: 'Wapu',
          lockFlow: '/wapu',
          onBack: _busy ? () {} : null,
          showSettings: false, // its gear has no PIN gate
          showSync: false,
          showInvoiceDebug: false,
          actions: [
            // The three wait while an order is created or funded: leaving the
            // sale then would drop the reply of the call that is out.
            //
            // The orders of this key, to follow one that was left or whose
            // create got no answer. Within reach while the till is locked too.
            if (_inSale)
              IconButton(
                key: const Key('wapu-history'),
                tooltip: context.tr('Historial').toUpperCase(),
                icon: const Icon(Icons.history, size: 26),
                onPressed: _busy ? null : _openHistory,
              ),
            // Within reach on every step, and while the till is locked too:
            // it is how the next customer is served.
            if (_inSale)
              IconButton(
                key: const Key('wapu-new-sale'),
                tooltip: context.tr('Nueva venta').toUpperCase(),
                icon: const Icon(Icons.add_circle_outline, size: 26),
                onPressed: _busy ? null : _newSale,
              ),
            // Nobody to keep a key for, and out of reach while the till is
            // locked.
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
                        onPressed: _busy ? null : _openConfig,
                      ),
              ),
          ],
        ),
        body: PosBody(child: _body(context)),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (!_signedIn) {
      return _notice(
          context, 'Ingresá con la dirección del comercio para usar Wapu');
    }
    if (!_loaded) return const SizedBox.shrink();
    if (_credentials == null) {
      // Out of reach while the till is locked, as the gear is: whoever is at
      // the counter must not set the key the customers' transfers go to.
      return ValueListenableBuilder<String?>(
        valueListenable: lockedFlow,
        builder: (context, locked, _) => _notice(
          context,
          'Configurá tu API key de Wapu',
          action: locked != null
              ? m.Text(
                  context.tr('Desbloqueá el POS para configurar Wapu'),
                  textAlign: TextAlign.center,
                  softWrap: true,
                  style: const TextStyle(color: AppColors.muted),
                )
              : FilledButton(
                  key: const Key('wapu-setup'),
                  onPressed: _openConfig,
                  child: Text(context.tr('Configurar')),
                ),
        ),
      );
    }
    return switch (_step) {
      _Step.destination => _destinationStep(context),
      _Step.amount => _amountStep(context),
      _Step.status => _statusStep(context),
    };
  }

  /// The order, with why it could not be funded or read again above it. The
  /// view scrolls, so it takes the room the reason leaves.
  Widget _statusStep(BuildContext context) {
    final error = _orderError;
    return Column(
      children: [
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: WapuErrorText(error),
          ),
        Expanded(
          child: WapuStatusView(
            order: _order!, // set with the step, cleared with it
            now: DateTime.now(),
            busy: _busy,
            onRequestFunding: _requestFunding,
            onNewSale: _newSale,
          ),
        ),
      ],
    );
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
    final createError = _createError;
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
              // The order that is being created is for this address, so it
              // waits for that.
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _step = _Step.destination;
                        _createError = null; // it was about the old address
                      }),
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
                // Before the price: the lines scroll, and this must be read.
                if (createError != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: WapuErrorText(createError, creating: true),
                  ),
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
          child: _busy
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 3),
                )
              : Text(context.tr('Confirmar')),
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
        _line(context, 'El cliente paga', formatArsCents(q.amountArsCents)),
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
