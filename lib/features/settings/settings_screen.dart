import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../domain/config/settings_state.dart';

/// Loaded once and reused across rebuilds.
final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

/// Shown immediately (and as a fallback if package_info isn't available on this
/// platform). Keep in sync with `pubspec.yaml`.
const String kFallbackVersion = '0.1.0';

/// Settings — feature toggles + Nostr relays, backed by the shared [appSettings]
/// store so changes actually gate other screens.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const PosAppBar(title: 'Settings', showSettings: false),
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
            children: [
              _card(Column(
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    activeTrackColor: AppColors.primary,
                    title: const Text('Propina'),
                    subtitle: const Text(
                        'Mostrar pantalla de propina antes de cobrar',
                        style: TextStyle(color: AppColors.muted, fontSize: 12)),
                    value: s.tipEnabled,
                    onChanged: setTipEnabled,
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    activeTrackColor: AppColors.primary,
                    title: const Text('Cuentas (tabs)'),
                    subtitle: const Text('Llevar cuenta por cliente',
                        style: TextStyle(color: AppColors.muted, fontSize: 12)),
                    value: s.tabEnabled,
                    onChanged: setTabEnabled,
                  ),
                ],
              )),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('RELAYS NOSTR',
                      style: TextStyle(
                          color: AppColors.muted,
                          fontSize: 12,
                          letterSpacing: 1.1,
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text('${s.relays.length} seleccionados',
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 12)),
                ],
              ),
              const SizedBox(height: 8),
              _card(Column(
                children: [
                  for (final r in kSuggestedRelays)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      activeColor: AppColors.primary,
                      title: Text(r, style: const TextStyle(fontSize: 13)),
                      value: s.relays.contains(r),
                      onChanged: (_) => toggleRelay(r),
                    ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: resetRelays,
                      icon: const Icon(Icons.restart_alt, size: 18),
                      label: const Text('Restablecer'),
                    ),
                  ),
                ],
              )),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(Widget child) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(
            color: AppColors.surface, borderRadius: BorderRadius.circular(12)),
        child: child,
      );
}
