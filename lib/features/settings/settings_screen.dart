import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../domain/config/session.dart';
import '../../domain/config/settings_state.dart';
import '../../domain/order/order_reset.dart';
import '../../platform/printer_channel.dart';

/// Loaded once and reused across rebuilds.
final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

/// Shown immediately (and as a fallback if package_info isn't available on this
/// platform). Keep in sync with `pubspec.yaml`.
const String kFallbackVersion = '0.1.0';

/// Settings — language, feature toggles, Nostr relays (add / edit / remove) and
/// the printer, backed by the shared [appSettings] store so changes take effect
/// across the app immediately.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PosAppBar(title: context.tr('Configuración'), showSettings: false),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: FutureBuilder<PackageInfo>(
            future: _packageInfo,
            builder: (context, snap) {
              final info = snap.data;
              final label = info != null
                  ? 'v${info.version} (${info.buildNumber})'
                  : 'v$kFallbackVersion';
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(label,
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 12)),
                ],
              );
            },
          ),
        ),
      ),
      body: ValueListenableBuilder<SettingsState>(
        valueListenable: appSettings,
        builder: (context, s, _) => PosBody(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: [
              _sectionHeader(context, 'Cuenta'),
              _card(Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      children: [
                        const Icon(Icons.storefront_outlined,
                            size: 20, color: AppColors.primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(merchantAddress.value,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 15)),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  InkWell(
                    onTap: () {
                      resetOrder();
                      context.go('/');
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Row(
                        children: [
                          const Icon(Icons.logout,
                              size: 20, color: AppColors.error),
                          const SizedBox(width: 10),
                          Text(context.tr('Cerrar sesión'),
                              style: const TextStyle(
                                  color: AppColors.error,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),
                ],
              )),
              const SizedBox(height: 20),
              _sectionHeader(context, 'General'),
              _card(Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: _LanguageSelector(current: s.languageCode),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    activeTrackColor: AppColors.primary,
                    title: Text(context.tr('Propina')),
                    subtitle: Text(
                        context.tr('Mostrar pantalla de propina antes de cobrar'),
                        style: const TextStyle(
                            color: AppColors.muted, fontSize: 12)),
                    value: s.tipEnabled,
                    onChanged: setTipEnabled,
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    activeTrackColor: AppColors.primary,
                    title: Text(context.tr('Cuentas (tabs)')),
                    subtitle: Text(context.tr('Llevar cuenta por cliente'),
                        style: const TextStyle(
                            color: AppColors.muted, fontSize: 12)),
                    value: s.tabEnabled,
                    onChanged: setTabEnabled,
                  ),
                ],
              )),
              const SizedBox(height: 20),
              _sectionHeader(context, 'Relays Nostr',
                  trailing:
                      '${s.relays.length} ${context.tr(s.relays.length == 1 ? 'relay' : 'relays')}'),
              _RelaysCard(relays: s.relays),
              const SizedBox(height: 20),
              _sectionHeader(context, 'Impresora'),
              _card(Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.print_outlined,
                            size: 20, color: AppColors.primary),
                        const SizedBox(width: 8),
                        Text(context.tr('Impresora ZCS SmartPos'),
                            style: const TextStyle(fontSize: 15)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () => _testPrint(context),
                      icon: const Icon(Icons.receipt_long, size: 20),
                      label: Text(context.tr('Probar impresora')),
                    ),
                  ],
                ),
              )),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  static Future<void> _testPrint(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
        content: Text(context.tr('Imprimiendo prueba…')),
        duration: const Duration(seconds: 1)));
    final res = await PrinterChannel.testPrint();
    if (!context.mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text(res.message),
      backgroundColor: res.ok ? AppColors.primary : AppColors.error,
    ));
  }
}

Widget _sectionHeader(BuildContext context, String key, {String? trailing}) =>
    Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Row(
        children: [
          Text(context.tr(key).toUpperCase(),
              style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 12,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w700)),
          const Spacer(),
          if (trailing != null)
            Text(trailing,
                style: const TextStyle(color: AppColors.muted, fontSize: 12)),
        ],
      ),
    );

Widget _card(Widget child) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
          color: AppColors.surface, borderRadius: BorderRadius.circular(16)),
      child: child,
    );

/// Segmented language selector (Español / English).
class _LanguageSelector extends StatelessWidget {
  final String current;
  const _LanguageSelector({required this.current});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.language, size: 20, color: AppColors.primary),
        const SizedBox(width: 8),
        Expanded(
            child: Text(context.tr('Idioma'),
                style: const TextStyle(fontSize: 15))),
        for (final l in AppLanguage.values)
          Padding(
            padding: EdgeInsets.only(left: l == AppLanguage.values.first ? 0 : 8),
            child: _chip(
              label: l.label,
              selected: current == l.code,
              onTap: () => setLanguage(l.code),
            ),
          ),
      ],
    );
  }

  Widget _chip(
      {required String label,
      required bool selected,
      required VoidCallback onTap}) {
    return Material(
      color: selected ? AppColors.primary : AppColors.background,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Text(label,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: selected ? AppColors.background : AppColors.onDark)),
        ),
      ),
    );
  }
}

/// The relays card: editable/removable active relays, an add field, quick-add
/// suggestions, and a reset.
class _RelaysCard extends StatefulWidget {
  final List<String> relays;
  const _RelaysCard({required this.relays});
  @override
  State<_RelaysCard> createState() => _RelaysCardState();
}

class _RelaysCardState extends State<_RelaysCard> {
  final _addCtrl = TextEditingController();

  @override
  void dispose() {
    _addCtrl.dispose();
    super.dispose();
  }

  void _snack(String msgKey) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.tr(msgKey)), backgroundColor: AppColors.error));

  void _submitAdd() {
    final text = _addCtrl.text;
    if (text.trim().isEmpty) return;
    if (addRelay(text)) {
      _addCtrl.clear();
      FocusScope.of(context).unfocus();
    } else {
      _snack('URL inválida o repetida');
    }
  }

  Future<void> _editRelay(int index, String current) async {
    final ctrl = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(context.tr('Editar relay')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            filled: true,
            fillColor: AppColors.background,
            hintText: 'wss://relay.example.com',
            border: OutlineInputBorder(
                borderSide: BorderSide.none,
                borderRadius: BorderRadius.all(Radius.circular(12))),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(context.tr('Cancelar'),
                style: const TextStyle(color: AppColors.muted)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: Text(context.tr('Guardar')),
          ),
        ],
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      if (!updateRelay(index, result)) _snack('URL inválida o repetida');
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.relays;
    final suggestions =
        kSuggestedRelays.where((r) => !active.contains(r)).toList();
    return _card(Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 4),
        for (var i = 0; i < active.length; i++) ...[
          if (i > 0) const Divider(height: 1),
          _relayRow(i, active[i], canDelete: active.length > 1),
        ],
        const SizedBox(height: 8),
        // Add a new relay.
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _addCtrl,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: AppColors.background,
                  hintText: 'wss://relay.example.com',
                  hintStyle:
                      const TextStyle(color: AppColors.muted, fontSize: 13),
                  border: const OutlineInputBorder(
                      borderSide: BorderSide.none,
                      borderRadius: BorderRadius.all(Radius.circular(12))),
                ),
                onSubmitted: (_) => _submitAdd(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 48),
                padding: const EdgeInsets.symmetric(horizontal: 18),
              ),
              onPressed: _submitAdd,
              child: Text(context.tr('Agregar')),
            ),
          ],
        ),
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(context.tr('Sugeridos'),
                style: const TextStyle(color: AppColors.muted, fontSize: 12)),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final r in suggestions)
                ActionChip(
                  backgroundColor: AppColors.background,
                  side: BorderSide.none,
                  avatar: const Icon(Icons.add,
                      size: 16, color: AppColors.primary),
                  label: Text(r.replaceFirst('wss://', ''),
                      style: const TextStyle(fontSize: 12)),
                  onPressed: () => toggleRelay(r),
                ),
            ],
          ),
        ],
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: resetRelays,
            icon: const Icon(Icons.restart_alt, size: 18),
            label: Text(context.tr('Restablecer')),
          ),
        ),
      ],
    ));
  }

  Widget _relayRow(int index, String url, {required bool canDelete}) {
    return InkWell(
      onTap: () => _editRelay(index, url),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.podcasts_rounded,
                size: 18, color: AppColors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(url.replaceFirst('wss://', ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14)),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.edit_outlined,
                  size: 18, color: AppColors.muted),
              onPressed: () => _editRelay(index, url),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close_rounded,
                  size: 18,
                  color: canDelete
                      ? AppColors.error
                      : AppColors.muted.withValues(alpha: 0.4)),
              onPressed: canDelete ? () => removeRelay(url) : null,
            ),
          ],
        ),
      ),
    );
  }
}
