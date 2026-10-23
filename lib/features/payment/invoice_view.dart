import 'dart:async';
import 'dart:math' as math;

import 'package:qr_flutter/qr_flutter.dart';

import '../../core/amount_pad.dart' show CurrencySelector;
import '../../core/i18n.dart';
import '../../core/sounds.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../core/widgets.dart' show BakedQr;
import '../../data/pricing/pricing_service.dart';
import '../../domain/config/currencies.dart';
import '../../domain/config/formatter.dart';
import '../../domain/config/selected_currency.dart';

/// The invoice / QR screen shown while charging.
///
/// It builds the whole template immediately — amount, currency switcher, QR
/// slot and the action buttons — with a staggered entrance, and plays a
/// "generating QR" scramble in the QR slot while the real invoice is fetched.
/// The switcher re-states the amount in SAT/USD/ARS at the live rate; the
/// invoice itself stays in sats. Only **Cancelar**
/// is enabled during loading. When [invoice] lands, the real QR cross-fades in,
/// "Esperando el pago…" reveals with an animation, and the remaining actions
/// (tap the QR to copy, Check event, Agregar a tab) become available.
class InvoiceView extends StatefulWidget {
  const InvoiceView({
    super.key,
    required this.sats,
    required this.invoice, // null while the invoice is still loading
    required this.nfcAvailable,
    required this.tabEnabled,
    required this.onCancel,
    required this.onCopy,
    required this.onCheck,
    required this.onAddTab,
  });

  final int sats;
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
    if (widget.invoice != null) AppSounds.play(AppSound.invoice);
  }

  @override
  void didUpdateWidget(InvoiceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.invoice != null && widget.invoice != oldWidget.invoice) {
      AppSounds.play(AppSound.invoice);
    }
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
    // No scroll: everything fits on screen, the QR takes what the rest leaves.
    return Column(
      children: [
        const SizedBox(height: 8),
        SizedBox(
          height: 24,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // "Esperando el pago…" — hidden while loading, revealed when ready.
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 450),
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween<Offset>(
                            begin: const Offset(0, 0.4), end: Offset.zero)
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
              // Tap-to-pay: an icon in the corner, appearing with the live
              // invoice, instead of a line of its own.
              Align(
                alignment: Alignment.centerRight,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  child: (ready && widget.nfcAvailable)
                      ? Icon(Icons.contactless_outlined,
                          key: const ValueKey('nfc'),
                          size: 24,
                          color: AppColors.primary,
                          semanticLabel:
                              context.tr('Acercá la tarjeta para pagar'))
                      : const SizedBox.shrink(key: ValueKey('nonfc')),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _stagger(
          1,
          // Rebuilds on each rate refresh and currency pick, so the amount
          // follows both.
          ListenableBuilder(
            listenable: Listenable.merge([pricing.notifier, selectedCurrency]),
            builder: (context, _) => Text(_amountLabel(),
                style:
                    const TextStyle(fontSize: 34, fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(height: 4),
        _stagger(
          2,
          Theme(
            data: Theme.of(context).copyWith(
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: ValueListenableBuilder(
              valueListenable: selectedCurrency,
              builder: (context, currency, _) => CurrencySelector(
                  value: currency, onChanged: setSelectedCurrency),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(child: _stagger(3, _qrCard(ready))),
        const SizedBox(height: 12),
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
        const SizedBox(height: 4),
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
    );
  }

  /// "21 sats", or the fiat equivalent ("≈ ARS 1.500"); "…" until rates load.
  /// The invoice itself stays in sats.
  String _amountLabel() {
    final currency = selectedCurrency.value;
    if (currency == Currency.sat) {
      return '${formatToPreference(Currency.sat, widget.sats)} sats';
    }
    final fiat = pricing.satsToFiat(widget.sats, currency);
    if (fiat == null) return '${currency.code} …';
    return '≈ ${currency.code} ${formatToPreference(currency, fiat)}';
  }

  /// The big white QR card, as large as the space left allows (up to almost
  /// the screen width). While loading it shows the scramble generator effect;
  /// when the invoice lands the real QR cross-fades in.
  Widget _qrCard(bool ready) {
    final screenW = MediaQuery.of(context).size.width;
    return LayoutBuilder(
      builder: (context, box) => _qrCardSized(
          ready, screenW, math.min(screenW - 50, box.maxHeight)),
    );
  }

  Widget _qrCardSized(bool ready, double screenW, double card) {
    return SizedBox(
      height: card,
      child: OverflowBox(
        maxWidth: screenW,
        child: GestureDetector(
          onTap: ready ? widget.onCopy : null, // the copy button
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
                  ? _invoiceQr()
                  : const _QrScramble(key: ValueKey('scramble')),
            ),
          ),
        ),
      ),
    );
  }

  Widget _invoiceQr() {
    final qr = QrValidator.validate(
      data: (widget.invoice ?? '').toUpperCase(),
      version: QrVersions.auto,
    ).qrCode!;
    return BakedQr(
      key: const ValueKey('qr'),
      moduleCount: qr.moduleCount,
      painter: QrPainter.withQr(qr: qr, gapless: true),
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
