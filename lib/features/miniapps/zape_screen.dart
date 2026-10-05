import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n.dart';
import '../../core/pin_dialog.dart';
import '../../core/print_error.dart';
import '../../core/sounds.dart';
import '../../core/theme.dart';
import '../../platform/printer_channel.dart';

/// Kiosk miniapp: prints a ZAPE strip of the chosen length (1 point = 1.7 cm)
/// while the sound holds its "e" for exactly as long as the printer runs, so a
/// longer strip sounds longer.
///
/// No back, settings, relay or debug buttons. The only way out is the X,
/// which asks for the miniapp PIN.
class ZapeScreen extends StatefulWidget {
  const ZapeScreen({super.key});

  @override
  State<ZapeScreen> createState() => _ZapeScreenState();
}

class _ZapeScreenState extends State<ZapeScreen> {
  var _points = 20;
  var _printing = false;

  Future<void> _zape() async {
    setState(() => _printing = true);
    await printOrAskToContinue(context, print: () async {
      AppSounds.startZape();
      final result = await PrinterChannel.printZape(_points);
      AppSounds.stopZape();
      return result;
    });
    if (mounted) setState(() => _printing = false);
  }

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
        body: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 260,
              height: 260,
              child: FilledButton(
                key: const Key('zape-button'),
                style: FilledButton.styleFrom(shape: const CircleBorder()),
                onPressed: _printing ? null : _zape,
                child: const Text('ZAPE',
                    style:
                        TextStyle(fontSize: 48, fontWeight: FontWeight.w800)),
              ),
            ),
            const SizedBox(height: 40),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                  '$_points ${context.tr(_points == 1 ? 'punto' : 'puntos')}',
                  style: const TextStyle(
                      fontFamily: 'ClimateCrisis', fontSize: 40)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Slider(
                key: const Key('zape-points'),
                value: _points.toDouble(),
                min: 1,
                max: 40,
                divisions: 39,
                activeColor: AppColors.primary,
                onChanged: _printing
                    ? null
                    : (v) => setState(() => _points = v.round()),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _close(BuildContext context) async {
    if (await confirmMiniappPin(context, action: 'Salir') && context.mounted) {
      context.go('/');
    }
  }
}
