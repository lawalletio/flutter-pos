import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../data/nostr/relay_sync_service.dart';
import '../domain/config/session.dart';
import 'flow_lock.dart';
import 'i18n.dart';
import 'pin_dialog.dart';
import 'theme.dart';
import 'ui.dart';

/// Shared UI building blocks for the POS screens.

/// [draw] rasterized once into a [width]×[height] px bitmap. Impeller has no
/// raster cache, so a static layer is re-shaded every frame anything on screen
/// animates; radial, sweep and diagonal gradients are slow on the Z92's GPU,
/// a bitmap of them is ~free.
ui.Image recordImage(int width, int height, void Function(Canvas canvas) draw) {
  final recorder = ui.PictureRecorder();
  draw(Canvas(recorder));
  final picture = recorder.endRecording();
  final image = picture.toImageSync(math.max(1, width), math.max(1, height));
  picture.dispose();
  return image;
}

/// [painter]'s QR drawn once into a bitmap, [size] wide or as wide as it can
/// be, like a `QrImageView` with no padding. A live `QrImageView` re-draws
/// every module each frame anything on screen animates (a spinner, a
/// breathing dot): ~28 ms a frame on the Z92.
class BakedQr extends StatefulWidget {
  const BakedQr(
      {super.key, required this.painter, required this.moduleCount, this.size});
  final QrPainter painter;

  /// The painted code's [QrCode.moduleCount]. QrPainter rounds a module to the
  /// nearest half pixel; rounded up, the code outgrows the bitmap and its
  /// edges are cut off. Sizing the bitmap to a whole number of half-pixel
  /// modules keeps every module in.
  final int moduleCount;
  final double? size;

  @override
  State<BakedQr> createState() => _BakedQrState();
}

class _BakedQrState extends State<BakedQr> {
  ui.Image? _image;
  QrPainter? _painter;

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final side = widget.size ?? box.biggest.shortestSide;
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final n = widget.moduleCount;
        final module = (side * dpr / n * 2).floorToDouble() / 2;
        final px = (module * n).round();
        final painter = _painter;
        if (_image?.width != px ||
            painter == null ||
            widget.painter.shouldRepaint(painter)) {
          _image?.dispose();
          _image = recordImage(px, px,
              (c) => widget.painter.paint(c, Size.square(px.toDouble())));
          _painter = widget.painter;
        }
        return SizedBox.square(
          dimension: side,
          child: Center(
            child: Semantics(
              label: 'qr code',
              child: RawImage(
                  image: _image,
                  width: px / dpr,
                  height: px / dpr,
                  fit: BoxFit.fill),
            ),
          ),
        );
      });
}

/// Top app bar with an optional back button and a settings gear (mirrors the
/// webapp's `layout/top.tsx` + `Navbar`).
///
/// Also the till's lock: [lockFlow] screens show a lock that keeps the till in
/// that flow (see [lockableFlows]). While locked every screen of the flow
/// shows only the unlock, which asks for the PIN and goes back to the hub.
class PosAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String? title;
  final bool showBack;
  final bool showSettings;

  /// Where the gear goes. The rueda points it at its own config.
  final String settingsRoute;

  /// Relay replication indicator, left of the settings gear. Spins while a
  /// sync is running; tapping it opens the progress and the log.
  final bool showSync;

  /// Screen-specific buttons, before the sync indicator and the gear.
  final List<Widget> actions;

  /// Opens the on-device log of every generated invoice.
  final bool showInvoiceDebug;

  /// Replaces the default pop. The payment wheel uses this to skip success.
  final VoidCallback? onBack;

  /// The flow this screen starts, a key of [lockableFlows]. Shows the lock.
  final String? lockFlow;

  const PosAppBar({
    super.key,
    this.title,
    this.showBack = true,
    this.showSettings = true,
    this.settingsRoute = '/settings',
    this.showSync = true,
    this.actions = const [],
    this.showInvoiceDebug = true,
    this.onBack,
    this.lockFlow,
  });

  @override
  Size get preferredSize => const Size.fromHeight(72);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: lockedFlow,
      builder: (context, locked, _) {
        final isLocked = locked != null;
        // The flow's first screen has nothing of the flow behind it.
        final atStart = isLocked && locked == lockFlow;
        return PopScope(
          canPop: !atStart,
          child: _bar(context, isLocked: isLocked, atStart: atStart),
        );
      },
    );
  }

  Widget _bar(BuildContext context,
      {required bool isLocked, required bool atStart}) {
    final back = showBack && !atStart;
    return AppBar(
      backgroundColor: AppColors.background,
      elevation: 0,
      toolbarHeight: 72,
      leadingWidth: 68,
      automaticallyImplyLeading: false,
      leading: back
          ? Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Material(
                color: AppColors.surface,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onBack ??
                      () =>
                          context.canPop() ? context.pop() : context.go('/hub'),
                  child: const SizedBox(
                    width: 48,
                    height: 48,
                    child: Icon(Icons.arrow_back, size: 26),
                  ),
                ),
              ),
            )
          : null,
      title: title == null
          ? null
          : Text(title!,
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
      actions: [
        ...actions,
        if (showInvoiceDebug && !isLocked)
          IconButton(
            tooltip: context.tr('Invoices generadas').toUpperCase(),
            icon: const Icon(Icons.bug_report_outlined, size: 26),
            onPressed: () => context.push('/invoice-debug'),
          ),
        if (showSync && !isLocked) const _SyncAction(),
        // Not mid-charge or mid-print: those screens hide back too.
        FlowLockButton(flow: lockFlow, enabled: showBack),
        if (showSettings && !isLocked)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton(
              icon: const Icon(Icons.settings_outlined, size: 26),
              onPressed: () => context.push(settingsRoute),
            ),
          ),
      ],
    );
  }
}

/// The till's lock (see [lockableFlows]). Unlocked, on a [flow] screen, it
/// locks to that flow; locked, on any screen, it asks for the PIN, unlocks and
/// goes back to the hub. Nothing otherwise.
class FlowLockButton extends StatelessWidget {
  const FlowLockButton({super.key, this.flow, this.enabled = true, this.color});

  final String? flow;
  final bool enabled;

  /// Of the open lock; the closed one is always the primary color.
  final Color? color;

  Future<void> _unlock(BuildContext context) async {
    if (!await confirmMiniappPin(context, action: 'Desbloquear')) return;
    lockedFlow.value = null;
    if (context.mounted) {
      context.go(merchantAddress.value.isEmpty ? '/' : '/hub');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: lockedFlow,
      builder: (context, locked, _) {
        if (locked != null) {
          return IconButton(
            key: const Key('flow-unlock'),
            tooltip: context.tr('Desbloquear').toUpperCase(),
            icon: const Icon(Icons.lock, size: 26, color: AppColors.primary),
            onPressed: enabled ? () => _unlock(context) : null,
          );
        }
        if (flow == null) return const SizedBox.shrink();
        return IconButton(
          key: const Key('flow-lock'),
          tooltip: context.tr('Bloquear').toUpperCase(),
          icon: Icon(Icons.lock_open_outlined, size: 26, color: color),
          onPressed: () => lockedFlow.value = flow,
        );
      },
    );
  }
}

/// Large tappable card used on the hub for venues and modes.
class PosCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? sublabel;
  final Color? color;
  final VoidCallback? onTap; // null: disabled
  const PosCard({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.sublabel,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.surface;
    return Material(
      color: c,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 20),
          child: Row(
            children: [
              Icon(icon, size: 34, color: AppColors.primary),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w600)),
                    if (sublabel != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(sublabel!,
                            style: const TextStyle(
                                fontSize: 14, color: AppColors.muted)),
                      ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 26, color: AppColors.muted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Centered content column with a max width (POS runs portrait/narrow).
class PosBody extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const PosBody({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Relay replication status in the app bar.
///
/// Shows a spinner while events are being pushed to relays that were missing
/// them, a red badge when a relay refused, and nothing eye-catching once
/// everything is in sync — the point is to be ignorable until it matters.
class _SyncAction extends StatelessWidget {
  const _SyncAction();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SyncReport>(
      valueListenable: relaySync.notifier,
      builder: (context, r, _) {
        if (r.phase == SyncPhase.idle && r.relays.isEmpty) {
          return const SizedBox.shrink();
        }
        // Red only when the sync as a whole failed — i.e. no relay was
        // reachable. Policy refusals are expected on a backfill, and a single
        // dead relay is normal; alarming on either just teaches the operator to
        // ignore this icon.
        final failed = r.phase == SyncPhase.failed;
        return IconButton(
          tooltip: context.tr('Relays').toUpperCase(),
          onPressed: () => context.push('/relays'),
          icon: r.isRunning
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.2, color: AppColors.primary),
                )
              : Icon(
                  failed ? Icons.cloud_off_outlined : Icons.cloud_done_outlined,
                  size: 26,
                  color: failed ? AppColors.error : null,
                ),
        );
      },
    );
  }
}
