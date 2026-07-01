import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Settings — feature toggles + Nostr relays (mock/local state for preview).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _tip = false;
  bool _tab = true;
  final List<String> _relays = [
    'wss://relay.damus.io',
    'wss://relay.masize.com',
  ];
  final _relayCtrl = TextEditingController();

  @override
  void dispose() {
    _relayCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const PosAppBar(title: 'Settings', showSettings: false),
      body: PosBody(
        child: ListView(
          children: [
            _card(Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeTrackColor: AppColors.primary,
                  title: const Text('Propina'),
                  subtitle: const Text('Mostrar pantalla de propina antes de cobrar',
                      style: TextStyle(color: AppColors.muted, fontSize: 12)),
                  value: _tip,
                  onChanged: (v) => setState(() => _tip = v),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeTrackColor: AppColors.primary,
                  title: const Text('Cuentas (tabs)'),
                  subtitle: const Text('Llevar cuenta por cliente',
                      style: TextStyle(color: AppColors.muted, fontSize: 12)),
                  value: _tab,
                  onChanged: (v) => setState(() => _tab = v),
                ),
              ],
            )),
            const SizedBox(height: 16),
            const Text('RELAYS NOSTR',
                style: TextStyle(
                    color: AppColors.muted,
                    fontSize: 12,
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            _card(Column(
              children: [
                for (final r in _relays)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: const Icon(Icons.check_circle,
                        color: AppColors.primary, size: 20),
                    title: Text(r, style: const TextStyle(fontSize: 13)),
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 16, color: AppColors.muted),
                      onPressed: () => setState(() => _relays.remove(r)),
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _relayCtrl,
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: 'wss://…',
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        final v = _relayCtrl.text.trim();
                        if (v.isNotEmpty) {
                          setState(() {
                            _relays.add(v);
                            _relayCtrl.clear();
                          });
                        }
                      },
                      child: const Text('Agregar'),
                    ),
                  ],
                ),
              ],
            )),
          ],
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
