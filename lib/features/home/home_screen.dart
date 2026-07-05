import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/lnurl/lnurl_service.dart';
import '../../domain/config/address_history.dart';
import '../../domain/config/session.dart';

/// Loaded once and reused across rebuilds.
final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

/// Popular Lightning-address providers, LaWallet ecosystem first, used to
/// autocomplete a typed username into full addresses.
const List<String> kPopularLnProviders = <String>[
  'lawallet.io',
  'lacrypta.ar',
  'walletofsatoshi.com',
  'blink.sv',
  'strike.me',
  'getalby.com',
];

/// Up to 7 live Lightning-address suggestions built from the written [history]
/// and popular [providers], filtered in real time by what's currently typed:
///
/// - `pepe`     → pepe@lawallet.io, pepe@lacrypta.ar, … (+ matching history)
/// - `pepe@bl`  → pepe@blink.sv (+ history starting with `pepe@bl`)
/// - empty      → recent history
///
/// History matches rank ahead of generated combos; the exact text already typed
/// is never suggested back; results are de-duplicated (case-insensitive).
List<String> buildAddressSuggestions(
  String input,
  List<String> history, {
  List<String> providers = kPopularLnProviders,
}) {
  final q = input.trim().toLowerCase();
  final out = <String>[];
  final seen = <String>{};
  void add(String s) {
    final key = s.toLowerCase();
    if (key == q) return; // don't suggest the exact text already typed
    if (seen.add(key)) out.add(s);
  }

  if (q.isEmpty) {
    for (final h in history) {
      add(h);
    }
  } else {
    final at = q.indexOf('@');
    if (at >= 0) {
      // Typing the domain part → complete it against the providers.
      final user = q.substring(0, at);
      final domainPart = q.substring(at + 1);
      for (final h in history) {
        if (h.toLowerCase().startsWith(q)) add(h);
      }
      if (user.isNotEmpty) {
        for (final p in providers) {
          if (p.startsWith(domainPart)) add('$user@$p');
        }
      }
    } else {
      // Username only → history matches first, then user@provider combos.
      for (final h in history) {
        if (h.toLowerCase().startsWith(q)) add(h);
      }
      for (final h in history) {
        if (h.toLowerCase().contains(q)) add(h);
      }
      for (final p in providers) {
        add('$q@$p');
      }
    }
  }
  return out.take(7).toList();
}

/// Matches a `user@domain.tld` Lightning address (email shape).
final RegExp _lnAddressRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// Whether [address] is a syntactically valid Lightning address (email regex).
bool isValidLightningAddress(String address) =>
    _lnAddressRegex.hasMatch(address.trim());

/// Home — merchant Lightning Address entry.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _ctrl = TextEditingController(text: 'barra@lacrypta.ar');
  final _focus = FocusNode();
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    addressHistory.load();
    // Flip the suffix arrow when the field gains/loses focus.
    _focus.addListener(() {
      if (mounted) setState(() {});
    });
    // Re-evaluate the "Configurar" enabled state as the address is typed.
    _ctrl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  List<String> _suggestions(String input) =>
      buildAddressSuggestions(input, addressHistory.notifier.value);

  bool get _isValidAddress => isValidLightningAddress(_ctrl.text);

  Future<void> _configure() async {
    var addr = _ctrl.text.trim().toLowerCase();
    if (addr.isEmpty) return;
    // Append the default domain when only a username is entered
    // (mirrors the webapp home behaviour).
    if (!addr.contains('@')) addr = '$addr@lacrypta.ar';
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await lnurl.validate(addr);
      merchantAddress.value = addr;
      addressHistory.add(addr);
      if (mounted) {
        context.go('/hub?address=${Uri.encodeComponent(addr)}');
      }
    } on LnurlException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'No se pudo validar la dirección');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const PosAppBar(showBack: false),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: FutureBuilder<PackageInfo>(
            future: _packageInfo,
            builder: (context, snap) {
              final info = snap.data;
              final label = info != null
                  ? 'v${info.version} (${info.buildNumber})'
                  : 'v0.1.3';
              return Text(label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.muted, fontSize: 12));
            },
          ),
        ),
      ),
      body: PosBody(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 48),
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Image.asset('assets/images/app_icon.png',
                    width: 96, height: 96),
              ),
            ),
            const SizedBox(height: 12),
            Text('LaWallet POS',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(context.tr('Ingresá la dirección Lightning del comercio'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.muted)),
            const SizedBox(height: 28),
            LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth; // match the dropdown to the input
                return RawAutocomplete<String>(
                  textEditingController: _ctrl,
                  focusNode: _focus,
                  optionsBuilder: (value) => _suggestions(value.text),
                  onSelected: (_) => _focus.unfocus(),
                  fieldViewBuilder:
                      (context, controller, focusNode, onFieldSubmitted) {
                    return TextField(
                      controller: controller,
                      focusNode: focusNode,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w600),
                      onSubmitted: (_) => onFieldSubmitted(),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: AppColors.surface,
                        hintText: 'user@lawallet.io',
                        border: const OutlineInputBorder(
                            borderSide: BorderSide.none,
                            borderRadius:
                                BorderRadius.all(Radius.circular(12))),
                        // Clear button (left) — wipes the whole address.
                        prefixIcon: controller.text.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close,
                                    size: 20, color: AppColors.muted),
                                onPressed: controller.clear,
                              ),
                        suffixIcon: IconButton(
                          icon: Icon(_focus.hasFocus
                              ? Icons.arrow_drop_up
                              : Icons.arrow_drop_down),
                          onPressed: () => _focus.hasFocus
                              ? _focus.unfocus()
                              : _focus.requestFocus(),
                        ),
                      ),
                    );
                  },
                  optionsViewBuilder: (context, onSelected, options) {
                    return Align(
                      alignment: Alignment.topLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Material(
                          color: AppColors.surface,
                          elevation: 10,
                          borderRadius: BorderRadius.circular(12),
                          clipBehavior: Clip.antiAlias,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                                minWidth: w, maxWidth: w, maxHeight: 340),
                            // Recompute against the live history so deleting a
                            // saved entry updates the list immediately.
                            child: ValueListenableBuilder<List<String>>(
                              valueListenable: addressHistory.notifier,
                              builder: (context, history, _) {
                                final items = _suggestions(_ctrl.text);
                                return ListView(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 4),
                                  shrinkWrap: true,
                                  children: [
                                    for (final opt in items)
                                      InkWell(
                                        onTap: () => onSelected(opt),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.fromLTRB(
                                                        16, 12, 8, 12),
                                                child: Text(opt,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                        fontSize: 16)),
                                              ),
                                            ),
                                            // Saved (localStorage) entries can
                                            // be removed from history with an X.
                                            if (history.contains(opt))
                                              IconButton(
                                                icon: const Icon(Icons.close,
                                                    size: 18),
                                                color: AppColors.muted,
                                                visualDensity:
                                                    VisualDensity.compact,
                                                tooltip: context.tr(
                                                    'Eliminar del historial'),
                                                onPressed: () => addressHistory
                                                    .remove(opt),
                                              ),
                                          ],
                                        ),
                                      ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: (_loading || !_isValidAddress) ? null : _configure,
              child: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(context.tr('Configurar')),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.error)),
            ],
          ],
        ),
      ),
    );
  }
}
