import 'package:flutter/material.dart' as m;

import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../core/widgets.dart';
import '../../domain/config/session.dart';
import 'wapu_account.dart';
import 'wapu_api.dart';
import 'wapu_error_text.dart';

/// The fallback copy of [wapuErrorKey]: also what a failed storage write says.
const _generic = 'No se pudo completar la operación';

/// The WapuPay key, backend URL and Beta features switch of the signed-in POS
/// user. Saving or forgetting pops with `true`, so the caller reloads.
///
/// A failed call shows through [WapuErrorText], with the backend's own message.
/// A message of our own is Material [m.Text], not the app's [Text], which would
/// uppercase it and squeeze a long one into a single line.
class WapuSettingsScreen extends StatefulWidget {
  const WapuSettingsScreen({super.key});

  @override
  State<WapuSettingsScreen> createState() => _WapuSettingsScreenState();
}

class _WapuSettingsScreenState extends State<WapuSettingsScreen> {
  final _key = TextEditingController();
  final _url = TextEditingController(text: kWapuDefaultBaseUrl);

  /// Whose credentials these are, for as long as the screen is open. Reading it
  /// again at save time could file a key under a user it was not typed for.
  final _merchant = merchantAddress.value;

  /// What is saved for [_merchant]. Null until loaded, and when nothing is.
  WapuCredentials? _saved;

  /// The Beta features switch: the account's `beta_version`, once it is known.
  bool _beta = true;

  /// A read or a write is under way, so every control waits. Starts on, while
  /// the saved credentials and the account's beta flag load.
  bool _busy = true;

  /// What went wrong, one thing at a time: the [WapuApiException] of a failed
  /// call, which [WapuErrorText] draws with the backend's own message, or the
  /// Spanish copy (a String, translated when drawn) of a problem of our own.
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _key.dispose();
    _url.dispose();
    super.dispose();
  }

  /// Shows what is saved, then reads the account's beta flag with that key. A
  /// failed read says why but leaves the screen usable: the key can be replaced
  /// or forgotten.
  Future<void> _load() async {
    final saved = await wapuAccounts.load(_merchant);
    if (!mounted) return;
    var beta = true;
    WapuApiException? error;
    if (saved != null) {
      setState(() {
        _saved = saved;
        _url.text = saved.baseUrl;
      });
      try {
        beta = await wapuCall(
            () => wapuApiFor(saved.baseUrl, saved.apiKey).betaEnabled());
      } on WapuApiException catch (e) {
        error = e;
      }
      if (!mounted) return;
    }
    setState(() {
      _beta = beta;
      _error = error;
      _busy = false;
    });
  }

  /// With a saved key the account changes now, and the switch goes back if it
  /// could not. Without one it is only what [_save] will ask for.
  Future<void> _toggle(bool on) async {
    final saved = _saved;
    if (saved == null) {
      setState(() => _beta = on);
      return;
    }
    setState(() {
      _beta = on;
      _busy = true;
      _error = null;
    });
    WapuApiException? error;
    try {
      await wapuCall(() => wapuApiFor(saved.baseUrl, saved.apiKey).setBeta(on));
    } on WapuApiException catch (e) {
      error = e;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (error != null) {
        _beta = !on;
        _error = error;
      }
    });
  }

  /// Checks the key against the account, saves it, and sets the account's beta
  /// flag to the switch, whichever way it differs. Nothing is saved for a key
  /// the backend refuses.
  Future<void> _save() async {
    // Nobody is signed in, so there is nowhere to keep a key: WapuAccounts
    // would drop it without a word and the screen would close as if saved.
    if (_merchant.trim().isEmpty) {
      setState(() => _error = _generic);
      return;
    }
    // The normalizer trims, and is the only guard against a URL that is not
    // https, or that carries credentials, a query or a fragment.
    final url = normalizeWapuBaseUrl(_url.text);
    if (url == null) {
      setState(() => _error = 'La URL tiene que empezar con https://');
      return;
    }
    // An empty field keeps the saved key. A pasted newline would break the
    // request header, hence the trim.
    final typed = _key.text.trim();
    final apiKey = typed.isEmpty ? _saved?.apiKey : typed;
    if (apiKey == null) {
      setState(() => _error = 'La API key no es válida');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = wapuApiFor(url, apiKey);
    Object? error;
    try {
      final beta = await wapuCall(api.betaEnabled);
      final credentials = WapuCredentials(apiKey: apiKey, baseUrl: url);
      await wapuAccounts.save(_merchant, credentials);
      // From here the key is saved, even if setting beta fails below.
      _saved = credentials;
      if (_beta != beta) await wapuCall(() => api.setBeta(_beta));
    } on WapuApiException catch (e) {
      error = e;
    } catch (_) {
      error = _generic; // the storage write failed
    }
    _finish(error);
  }

  Future<void> _forget() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      await wapuAccounts.forget(_merchant);
    } catch (_) {
      error = _generic; // the storage write failed
    }
    _finish(error);
  }

  /// Closes the screen when [error] is null, so the caller reloads. Otherwise
  /// stays and shows it. A closing screen stays busy, so a second tap during the
  /// pop animation does nothing.
  void _finish(Object? error) {
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).maybePop(true);
    } else {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final saved = _saved;
    final error = _error;
    return Scaffold(
      appBar: PosAppBar(
        title: context.tr('Configuración de Wapu'),
        showSettings: false,
        showSync: false,
        showInvoiceDebug: false,
      ),
      body: PosBody(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            SizedBox(
              height: 4,
              child: _busy ? const LinearProgressIndicator() : null,
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('wapu-key'),
              controller: _key,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: _decoration(
                context.tr('API key'),
                hint: saved == null
                    ? null
                    : '${context.tr('Guardada: ')}••••${_last4(saved.apiKey)}',
              ),
            ),
            SwitchListTile(
              key: const Key('wapu-beta'),
              contentPadding: EdgeInsets.zero,
              title: Text(context.tr('Beta features')),
              value: _beta,
              onChanged: _busy ? null : _toggle,
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 12),
              title: Text(context.tr('Avanzado')),
              children: [
                TextField(
                  key: const Key('wapu-url'),
                  controller: _url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: _decoration(context.tr('URL del backend')),
                ),
              ],
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: error is WapuApiException
                    ? WapuErrorText(error)
                    : m.Text(
                        context.tr(error.toString()),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.error),
                      ),
              ),
            FilledButton(
              key: const Key('wapu-save'),
              onPressed: _busy ? null : _save,
              child: Text(context.tr('Guardar')),
            ),
            if (saved != null)
              TextButton(
                key: const Key('wapu-forget'),
                onPressed: _busy ? null : _forget,
                style: TextButton.styleFrom(foregroundColor: AppColors.error),
                child: Text(context.tr('Olvidar key')),
              ),
          ],
        ),
      ),
    );
  }
}

/// A filled field with the label always up, so a hint can sit beside it.
InputDecoration _decoration(String label, {String? hint}) => InputDecoration(
      labelText: label,
      hintText: hint,
      floatingLabelBehavior: FloatingLabelBehavior.always,
      filled: true,
      fillColor: AppColors.surface,
      border: const UnderlineInputBorder(
        borderSide: BorderSide.none,
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    );

String _last4(String key) =>
    key.length > 4 ? key.substring(key.length - 4) : key;
