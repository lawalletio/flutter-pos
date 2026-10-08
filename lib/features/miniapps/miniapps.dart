import 'dart:math' as math;

import 'package:go_router/go_router.dart';

import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../core/widgets.dart';
import '../../data/lnurl/lnurl_service.dart';
import '../../domain/config/session.dart';
import '../../platform/printer_channel.dart';

/// What a miniapp needs before it can be opened.
enum MiniappRequirement {
  lud16('Falta configurar la dirección Lightning'),
  lud21('La dirección Lightning no soporta LUD-21'),
  printer('Impresora no disponible');

  const MiniappRequirement(this.message);
  final String message;
}

class MiniappManifest {
  const MiniappManifest({
    required this.name,
    required this.sublabel,
    required this.route,
    required this.icon,
    this.requires = const {},
  });

  final String name;
  final String sublabel;
  final String route;
  final IconData icon;
  final Set<MiniappRequirement> requires;
}

const miniapps = [
  MiniappManifest(
    name: 'ZAPE',
    sublabel: 'Modo kiosco',
    route: '/zape',
    icon: Icons.celebration_outlined,
    requires: {
      MiniappRequirement.lud16,
      MiniappRequirement.lud21,
      MiniappRequirement.printer,
    },
  ),
];

/// The requirements of [app] this device and account don't meet.
Future<List<MiniappRequirement>> missingRequirements(
    MiniappManifest app) async {
  final address = merchantAddress.value.trim();
  final missing = <MiniappRequirement>[];
  for (final r in app.requires) {
    final ok = switch (r) {
      MiniappRequirement.lud16 => address.isNotEmpty,
      // Without an address the lud16 line already says it all.
      MiniappRequirement.lud21 =>
        address.isEmpty || await _supportsVerify(address),
      MiniappRequirement.printer => await PrinterChannel.isAvailable(),
    };
    if (!ok) missing.add(r);
  }
  return missing;
}

final _verifyByAddress = <String, bool>{};

/// LUD-21 only shows up on an invoice, so this asks for the smallest one.
// ponytail: mints a throwaway invoice once per address per run; drop it if
// providers start advertising LUD-21 in the payRequest.
Future<bool> _supportsVerify(String address) async {
  final known = _verifyByAddress[address];
  if (known != null) return known;
  try {
    final params = await lnurl.resolve(address);
    final sats = math.max(1, (params.minSendable + 999) ~/ 1000);
    final inv = await lnurl.requestInvoice(address, sats);
    return _verifyByAddress[address] = inv.verify != null;
  } catch (_) {
    return false; // offline or bad address: check again next time
  }
}

/// A miniapp's card. Disabled, with the reasons in red, until every
/// requirement in its manifest is met.
class MiniappTile extends StatefulWidget {
  const MiniappTile({super.key, required this.app});

  final MiniappManifest app;

  @override
  State<MiniappTile> createState() => _MiniappTileState();
}

class _MiniappTileState extends State<MiniappTile> {
  late final _missing = missingRequirements(widget.app);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<MiniappRequirement>>(
      future: _missing,
      builder: (context, snap) {
        final missing = snap.data;
        final ready = missing != null && missing.isEmpty;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Opacity(
              opacity: ready ? 1 : 0.45,
              child: PosCard(
                key: Key('miniapp-${widget.app.route}'),
                icon: widget.app.icon,
                label: widget.app.name,
                sublabel: context.tr(widget.app.sublabel),
                onTap: ready ? () => context.go(widget.app.route) : null,
              ),
            ),
            for (final r in missing ?? const <MiniappRequirement>[])
              Padding(
                padding: const EdgeInsets.only(top: 8, left: 4),
                child: Text(context.tr(r.message),
                    style: const TextStyle(
                        color: AppColors.error, fontWeight: FontWeight.w600)),
              ),
          ],
        );
      },
    );
  }
}
