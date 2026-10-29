import 'package:flutter/material.dart' as m;
import 'package:go_router/go_router.dart';

import '../../core/flow_lock.dart';
import '../../core/i18n.dart';
import '../../core/pin_dialog.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../core/widgets.dart';
import '../../data/lnurl/lnurl_service.dart';
import '../../domain/config/session.dart';
import '../cards/cards_widgets.dart' show TokenScanPage;
import 'wapu_account.dart';
import 'wapu_destination.dart';

/// Where the sale is: the customer's address, then the amount, then the order.
enum _Step { destination, amount, status }

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
  /// sats to. Set from the amount step on. Nothing reads it until that step is
  /// built, which drops the ignore.
  // ignore: unused_field
  String? _address;

  /// A lookup of the typed address is under way, so the first step waits.
  bool _checking = false;

  /// Why the address cannot be used, as Spanish source text.
  String? _error;

  /// Counts sales. Whatever is still on its way for an earlier one compares it
  /// when it lands, and is dropped.
  int _gen = 0;

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
  }

  Future<void> _load() async {
    final load = ++_loads;
    final credentials = await wapuAccounts.load(merchantAddress.value);
    if (!mounted || load != _loads) return;
    setState(() {
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
      _Step.amount || _Step.status => const SizedBox(),
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
}
