import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/i18n.dart';
import '../../core/theme.dart';

/// The invoice / QR screen shown while charging.
///
/// It builds the whole template immediately — amount, fiat, QR slot and the
/// action buttons — with a staggered entrance, and plays a "generating QR"
/// scramble in the QR slot while the real invoice is fetched. Only **Cancelar**
/// is enabled during loading. When [invoice] lands, the real QR cross-fades in,
/// "Esperando el pago…" reveals with an animation, and the remaining actions
/// (Copiar invoice, Check event, Agregar a tab) become available.
class InvoiceView extends StatefulWidget {
  const InvoiceView({
    super.key,
    required this.satsStr,
    required this.arsStr,
    required this.invoice, // null while the invoice is still loading
    required this.nfcAvailable,
    required this.tabEnabled,
    required this.onCancel,
    required this.onCopy,
    required this.onCheck,
    required this.onAddTab,
  });

  final String satsStr;
  final String arsStr;
  final String? invoice;
  final bool nfcAvailable;
  final bool tabEnabled;
  final VoidCallback onCancel;
  final VoidCallback onCopy;
  final VoidCallback onCheck;
  final VoidCallback onAddTab;

  @override
  State<InvoiceView> createState() => _InvoiceViewState();
}

class _InvoiceViewState extends State<InvoiceView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance;

  bool get _ready => widget.invoice != null;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    )..forward();
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  /// Fade + slide an item up into place, staggered by [order].
  Widget _stagger(int order, Widget child) {
    final start = (order * 0.1).clamp(0.0, 0.7);
    final anim = CurvedAnimation(
      parent: _entrance,
      curve: Interval(start, (start + 0.55).clamp(0.0, 1.0),
          curve: Curves.easeOutCubic),
    );
    return AnimatedBuilder(
      animation: anim,
      builder: (context, child) => Opacity(
        opacity: anim.value.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, 18 * (1 - anim.value)),
          child: child,
        ),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ready = _ready;
    return SingleChildScrollView(
      child: Column(
        children: [
          const SizedBox(height: 8),
          // "Esperando el pago…" — hidden while loading, revealed when ready.
          SizedBox(
            height: 24,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 450),
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position:
                      Tween<Offset>(begin: const Offset(0, 0.4), end: Offset.zero)
                          .animate(anim),
                  child: child,
                ),
              ),
              child: ready
                  ? Row(
                      key: const ValueKey('waiting'),
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 10),
                        Text(context.tr('Esperando el pago…'),
                            style: const TextStyle(color: AppColors.muted)),
                      ],
                    )
                  : const SizedBox.shrink(key: ValueKey('empty')),
            ),
          ),
          const SizedBox(height: 18),
          _stagger(
            1,
            Text('${widget.satsStr} sats',
                style:
                    const TextStyle(fontSize: 34, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 4),
          _stagger(
            2,
            Text('≈ ${widget.arsStr} ARS',
                style: const TextStyle(color: AppColors.muted)),
          ),
          const SizedBox(height: 20),
          _stagger(3, _qrCard(ready)),
          const SizedBox(height: 6),
          _stagger(
            4,
            TextButton.icon(
              onPressed: ready ? widget.onCopy : null,
              icon: const Icon(Icons.copy, size: 15),
              label: Text(context.tr('Copiar invoice')),
            ),
          ),
          const SizedBox(height: 8),
          // Tap-to-pay hint appears with the live invoice.
          SizedBox(
            height: 30,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              child: (ready && widget.nfcAvailable)
                  ? Row(
                      key: const ValueKey('nfc'),
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.contactless_outlined,
                            size: 18, color: AppColors.primary),
                        const SizedBox(width: 8),
                        Text(context.tr('Acercá la tarjeta para pagar'),
                            style: const TextStyle(color: AppColors.primary)),
                      ],
                    )
                  : const SizedBox.shrink(key: ValueKey('nonfc')),
            ),
          ),
          const SizedBox(height: 4),
          _stagger(
            5,
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: widget.onCancel, // always available
                child: Text(context.tr('Cancelar')),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _stagger(
            6,
            Row(
              children: [
                if (widget.tabEnabled)
                  Expanded(
                    child: TextButton.icon(
                      onPressed: ready ? widget.onAddTab : null,
                      icon: const Icon(Icons.add_card, size: 18),
                      label: Text(context.tr('Agregar a tab')),
                    ),
                  ),
                Expanded(
                  child: TextButton(
                    onPressed: ready ? widget.onCheck : null,
                    child: Text(context.tr('Check event')),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// The big white QR card. While loading it shows the scramble generator
  /// effect; when the invoice lands the real QR cross-fades in.
  Widget _qrCard(bool ready) {
    final screenW = MediaQuery.of(context).size.width;
    final card = screenW - 50;
    return SizedBox(
      height: card,
      child: OverflowBox(
        maxWidth: screenW,
        child: GestureDetector(
          onLongPress: ready ? widget.onCopy : null,
          child: Container(
            width: card,
            height: card,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 320),
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.94, end: 1.0).animate(
                      CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
                  child: child,
                ),
              ),
              child: ready
                  ? QrImageView(
                      key: const ValueKey('qr'),
                      data: (widget.invoice ?? '').toUpperCase(),
                      version: QrVersions.auto,
                      padding: EdgeInsets.zero,
                    )
                  : const _QrScramble(key: ValueKey('scramble')),
            ),
          ),
        ),
      ),
    );
  }
}

/// A looping "the QR is being generated" effect: static finder patterns in the
/// corners with the data modules scrambling randomly, drawn dark-on-white.
class _QrScramble extends StatefulWidget {
  const _QrScramble({super.key});

  @override
  State<_QrScramble> createState() => _QrScrambleState();
}

class _QrScrambleState extends State<_QrScramble> {
  static const int _n = 25;
  final math.Random _rng = math.Random();
  Timer? _timer;
  late List<bool> _cells;

  @override
  void initState() {
    super.initState();
    _cells = _generate();
    _timer = Timer.periodic(const Duration(milliseconds: 90), (_) {
      if (mounted) setState(() => _cells = _generate());
    });
  }

  List<bool> _generate() =>
      List<bool>.generate(_n * _n, (_) => _rng.nextDouble() < 0.5);

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: CustomPaint(painter: _QrScramblePainter(cells: _cells, n: _n)),
          ),
          // A spinner over the centre, on a soft white disc so it stays legible
          // against the scrambling modules.
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 12,
                ),
              ],
            ),
            alignment: Alignment.center,
            child: const SizedBox(
              width: 34,
              height: 34,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QrScramblePainter extends CustomPainter {
  _QrScramblePainter({required this.cells, required this.n});

  final List<bool> cells;
  final int n;

  static const int _finder = 7;
  static const Color _dark = Color(0xFF1C1C1C);

  bool _inFinder(int r, int c) {
    final tl = r < _finder && c < _finder;
    final tr = r < _finder && c >= n - _finder;
    final bl = r >= n - _finder && c < _finder;
    return tl || tr || bl;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / n;
    final dark = Paint()..color = _dark;

    // Scrambling data modules (skip the finder-pattern zones).
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (_inFinder(r, c) || !cells[r * n + c]) continue;
        canvas.drawRect(Rect.fromLTWH(c * cell, r * cell, cell, cell), dark);
      }
    }

    // Static finder patterns give it an unmistakably "QR" silhouette.
    _drawFinder(canvas, 0, 0, cell, dark);
    _drawFinder(canvas, 0, n - _finder, cell, dark);
    _drawFinder(canvas, n - _finder, 0, cell, dark);
  }

  void _drawFinder(Canvas canvas, int r0, int c0, double cell, Paint dark) {
    final x = c0 * cell, y = r0 * cell, s = _finder * cell;
    canvas.drawRect(Rect.fromLTWH(x, y, s, s), dark); // 7×7 outer
    canvas.drawRect(
      Rect.fromLTWH(x + cell, y + cell, s - 2 * cell, s - 2 * cell),
      Paint()..color = Colors.white, // 5×5 white
    );
    canvas.drawRect(
      Rect.fromLTWH(x + 2 * cell, y + 2 * cell, s - 4 * cell, s - 4 * cell),
      dark, // 3×3 core
    );
  }

  @override
  bool shouldRepaint(covariant _QrScramblePainter old) => old.cells != cells;
}
