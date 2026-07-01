import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../domain/config/address_history.dart';
import '../../domain/config/session.dart';

/// Home — merchant Lightning Address entry. (UI-only mock: any address → hub.)
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _ctrl = TextEditingController(text: 'barra@lacrypta.ar');

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const PosAppBar(showBack: false),
      body: PosBody(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.bolt, color: AppColors.primary, size: 56),
            const SizedBox(height: 12),
            Text('LaWallet POS',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Text('Ingresá la dirección Lightning del comercio',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.muted)),
            const SizedBox(height: 28),
            TextField(
              controller: _ctrl,
              textAlign: TextAlign.center,
              decoration: const InputDecoration(
                filled: true,
                fillColor: AppColors.surface,
                hintText: 'usuario@lawallet.ar',
                border: OutlineInputBorder(
                    borderSide: BorderSide.none,
                    borderRadius: BorderRadius.all(Radius.circular(12))),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                var addr = _ctrl.text.trim().toLowerCase();
                if (addr.isEmpty) return;
                // Append the default domain when only a username is entered
                // (mirrors the webapp home behaviour).
                if (!addr.contains('@')) addr = '$addr@lacrypta.ar';
                merchantAddress.value = addr;
                addressHistory.add(addr);
                context.go('/hub?address=${Uri.encodeComponent(addr)}');
              },
              child: const Text('Configurar'),
            ),
            const SizedBox(height: 24),
            const Text('v0.1.0 · M0 preview',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.muted, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
