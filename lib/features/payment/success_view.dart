import 'dart:math';

import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/i18n.dart';
import '../../core/theme.dart';

/// Spectacular "payment credited" celebration: confetti burst + rain, an
/// elastic pop-in check circle with expanding ripples, a stroke-drawn checkmark,
/// and content that fades/slides up.
///
/// Prize grants are a **second beat**: the lottery in [PaymentScreen] finishes
/// after the receipt prints, so [prizeText] is usually null on first frame and
/// arrives later via [didUpdateWidget].
class PaymentSuccessView extends StatefulWidget {
  final String satsStr;
  final String arsStr;

  /// The coupon applied, if any: its name and what it took off. Shown on the
  /// same screen as the amount, so the cashier can answer "¿me lo tomó?"
  /// without reaching for the ticket.
  final String? couponName;
  final String? discountStr;

  /// Prize voucher won after payment (separate from discount coupons).
  final String? prizeText;
  final bool prizePrinted;
  final bool printingPrize;
  final Future<void> Function()? onPrintPrize;

  /// Opens the fortune wheel. Null hides the button.
  final VoidCallback? onSpinWheel;

  final VoidCallback onBack;
  const PaymentSuccessView({
    super.key,
    required this.satsStr,
    required this.arsStr,
    required this.onBack,
    this.couponName,
    this.discountStr,
    this.prizeText,
    this.prizePrinted = false,
    this.printingPrize = false,
    this.onPrintPrize,
    this.onSpinWheel,
  });

  @override
  State<PaymentSuccessView> createState() => _PaymentSuccessViewState();
}

class _PaymentSuccessViewState extends State<PaymentSuccessView>
    with TickerProviderStateMixin {
  late final AnimationController _intro; // one-shot: circle + check + content
  late final AnimationController _pulse; // looping ripples + glow
  late final ConfettiController _burst; // center explosion
  late final ConfettiController _rainL; // top-left rain
  late final ConfettiController _rainR; // top-right rain

  late final AnimationController _prizeBeat;
  late final AnimationController _prizeOut;
  late final Animation<double> _circleScale;
  late final Animation<double> _checkDraw;
  late final Animation<double> _contentT;
  late final Animation<double> _prizeFade;
  late final Animation<double> _prizeScale;
  late final Animation<double> _prizeOutScale;
  late final Animation<double> _prizeOutFade;
  late final ConfettiController _prizeBurst;
  late final ConfettiController _prizeRain;
  late final AnimationController _wheelIn;
  late final AnimationController _wheelLoop;
  late final AnimationController _pull;

  final _startedAt = DateTime.now();
  bool _prizeBeatQueued = false;
  bool _prizeDismissed = false;
  bool _wheelArmed = false;

  static const _festive = [
    AppColors.primary,
    Color(0xFFFFD166),
    Color(0xFFFFFFFF),
    Color(0xFF06D6A0),
    Color(0xFF9B8CFF),
  ];

  /// Distinct from the payment burst: warm gold / coral, not the green rain.
  static const _prizeFestive = [
    Color(0xFFFFD166),
    Color(0xFFFF8C42),
    Color(0xFFFFF3B0),
    Color(0xFFFFFFFF),
    Color(0xFFFF4D8D),
    Color(0xFFFFC857),
  ];

  bool get _hasPrize =>
      widget.prizeText != null && widget.prizeText!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400));
    _pulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1800))
      ..repeat();
    _burst = ConfettiController(duration: const Duration(milliseconds: 900));
    _rainL = ConfettiController(duration: const Duration(seconds: 3));
    _rainR = ConfettiController(duration: const Duration(seconds: 3));

    _circleScale = CurvedAnimation(
        parent: _intro,
        curve: const Interval(0.0, 0.55, curve: Curves.elasticOut));
    _checkDraw = CurvedAnimation(
        parent: _intro,
        curve: const Interval(0.45, 0.75, curve: Curves.easeInOut));
    _contentT = CurvedAnimation(
        parent: _intro,
        curve: const Interval(0.6, 1.0, curve: Curves.easeOut));

    _prizeBeat = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1100));
    _prizeFade = CurvedAnimation(
        parent: _prizeBeat,
        curve: const Interval(0.0, 0.4, curve: Curves.easeOut));
    _prizeScale = Tween<double>(begin: 0.78, end: 1).animate(CurvedAnimation(
        parent: _prizeBeat,
        curve: const Interval(0.0, 0.85, curve: Curves.elasticOut)));
    // Pop slightly then shrink to nothing when the cashier taps print.
    _prizeOut = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 360));
    _prizeOutScale = Tween<double>(begin: 1, end: 0).animate(CurvedAnimation(
        parent: _prizeOut, curve: Curves.easeInBack));
    _prizeOutFade = Tween<double>(begin: 1, end: 0).animate(CurvedAnimation(
        parent: _prizeOut,
        curve: const Interval(0.0, 0.75, curve: Curves.easeIn)));
    _prizeBurst =
        ConfettiController(duration: const Duration(milliseconds: 1400));
    _prizeRain = ConfettiController(duration: const Duration(milliseconds: 2400));
    _wheelIn = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 880));
    _wheelLoop = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200));
    _pull = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2600));

    // Kick off the show.
    HapticFeedback.heavyImpact();
    _intro.forward();
    _burst.play();
    _rainL.play();
    _rainR.play();
    if (widget.prizePrinted) _prizeDismissed = true;
    _schedulePrizeBeat();
    _armWheel();
  }

  @override
  void didUpdateWidget(PaymentSuccessView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final hadPrize =
        oldWidget.prizeText != null && oldWidget.prizeText!.isNotEmpty;
    if (_hasPrize && !hadPrize) {
      _schedulePrizeBeat();
    }
    // Auto-print: don't leave the locked Impreso card on screen.
    if (widget.prizePrinted && !oldWidget.prizePrinted) {
      _dismissPrizeCard();
    }
    if (widget.onSpinWheel != null && oldWidget.onSpinWheel == null) {
      _armWheel();
    }
  }

  void _armWheel() {
    if (_wheelArmed || widget.onSpinWheel == null) return;
    _wheelArmed = true;
    _pull.repeat();
    _wheelLoop.repeat();
    _wheelIn.forward();
  }

  void _onPrintPrizeTap() {
    if (_prizeDismissed || _prizeOut.isAnimating) return;
    final printPrize = widget.onPrintPrize;
    if (printPrize == null) return;
    _dismissPrizeCard();
    printPrize();
  }

  void _dismissPrizeCard() {
    if (_prizeDismissed || _prizeOut.isAnimating || _prizeOut.isCompleted) {
      return;
    }
    HapticFeedback.mediumImpact();
    _prizeOut.forward().whenComplete(() {
      if (!mounted) return;
      setState(() => _prizeDismissed = true);
    });
  }

  /// Lottery runs after the ticket prints, so the prize usually lands on a
  /// widget that already finished [initState] with no prize.
  void _schedulePrizeBeat() {
    if (!_hasPrize || _prizeBeatQueued || _prizeBeat.isCompleted) return;
    _prizeBeatQueued = true;
    final elapsed = DateTime.now().difference(_startedAt);
    const beatAt = Duration(milliseconds: 1500);
    final wait = beatAt - elapsed;
    Future<void>.delayed(wait > Duration.zero ? wait : Duration.zero, () {
      if (!mounted) return;
      // Confetti widgets are inserted with the prize card; play after layout.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _prizeBeat.isCompleted || _prizeBeat.isAnimating) {
          return;
        }
        HapticFeedback.heavyImpact();
        _prizeBurst.play();
        _prizeRain.play();
        _prizeBeat.forward();
      });
      setState(() {});
    });
  }

  @override
  void dispose() {
    _intro.dispose();
    _pulse.dispose();
    _burst.dispose();
    _rainL.dispose();
    _rainR.dispose();
    _prizeBeat.dispose();
    _prizeOut.dispose();
    _prizeBurst.dispose();
    _prizeRain.dispose();
    _wheelIn.dispose();
    _wheelLoop.dispose();
    _pull.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final offerWheel = widget.onSpinWheel != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (offerWheel)
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _CenterPullPainter(repaint: _pull),
                ),
              ),
            ),
          ),
        Align(
          alignment: Alignment.topLeft,
          child: ConfettiWidget(
            confettiController: _rainL,
            blastDirection: pi / 3,
            emissionFrequency: 0.04,
            numberOfParticles: 6,
            gravity: 0.25,
            maxBlastForce: 22,
            minBlastForce: 8,
            colors: _festive,
          ),
        ),
        Align(
          alignment: Alignment.topRight,
          child: ConfettiWidget(
            confettiController: _rainR,
            blastDirection: 2 * pi / 3,
            emissionFrequency: 0.04,
            numberOfParticles: 6,
            gravity: 0.25,
            maxBlastForce: 22,
            minBlastForce: 8,
            colors: _festive,
          ),
        ),
        if (_hasPrize) ...[
          Align(
            alignment: Alignment.center,
            child: ConfettiWidget(
              confettiController: _prizeBurst,
              blastDirectionality: BlastDirectionality.explosive,
              numberOfParticles: 40,
              maxBlastForce: 34,
              minBlastForce: 16,
              gravity: 0.16,
              emissionFrequency: 0.08,
              colors: _prizeFestive,
              createParticlePath: _starPath,
            ),
          ),
          Align(
            alignment: Alignment.topCenter,
            child: ConfettiWidget(
              confettiController: _prizeRain,
              blastDirection: pi / 2,
              emissionFrequency: 0.045,
              numberOfParticles: 10,
              gravity: 0.2,
              maxBlastForce: 18,
              minBlastForce: 6,
              colors: _prizeFestive,
            ),
          ),
        ],
        LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Column(
                  mainAxisAlignment: offerWheel
                      ? MainAxisAlignment.start
                      : MainAxisAlignment.center,
                  children: [
                    if (offerWheel) const SizedBox(height: 8),
                    SizedBox(
                      width: _hasPrize ? 160 : (offerWheel ? 132 : 200),
                      height: _hasPrize ? 160 : (offerWheel ? 132 : 200),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          AnimatedBuilder(
                            animation: _pulse,
                            builder: (_, __) => CustomPaint(
                              size: Size.square(
                                  _hasPrize ? 160 : (offerWheel ? 132 : 200)),
                              painter: _RipplePainter(_pulse.value),
                            ),
                          ),
                          ConfettiWidget(
                            confettiController: _burst,
                            blastDirectionality: BlastDirectionality.explosive,
                            numberOfParticles: 24,
                            maxBlastForce: 28,
                            minBlastForce: 12,
                            gravity: 0.3,
                            colors: _festive,
                          ),
                          ScaleTransition(
                            scale: _circleScale,
                            child: Container(
                              width: _hasPrize ? 100 : (offerWheel ? 84 : 120),
                              height: _hasPrize ? 100 : (offerWheel ? 84 : 120),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.primary,
                                boxShadow: [
                                  BoxShadow(
                                    color: AppColors.primary
                                        .withValues(alpha: 0.55),
                                    blurRadius: 36,
                                    spreadRadius: 4,
                                  ),
                                ],
                              ),
                              child: AnimatedBuilder(
                                animation: _checkDraw,
                                builder: (_, __) => CustomPaint(
                                  painter: _CheckPainter(_checkDraw.value),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    AnimatedBuilder(
                      animation: _contentT,
                      builder: (_, child) => Opacity(
                        opacity: _contentT.value,
                        child: Transform.translate(
                          offset: Offset(0, 24 * (1 - _contentT.value)),
                          child: child,
                        ),
                      ),
                      child: Column(
                        children: [
                          Text(context.tr('¡Pago acreditado!'),
                              style: const TextStyle(
                                  fontSize: 26, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 10),
                          Text('${widget.satsStr} sats',
                              style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.primary)),
                          Text('≈ ${widget.arsStr} ARS',
                              style: const TextStyle(
                                  color: AppColors.muted, fontSize: 14)),
                          if (widget.couponName != null) ...[
                            const SizedBox(height: 14),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 8),
                              decoration: BoxDecoration(
                                color: AppColors.surface,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.local_offer,
                                      size: 16, color: AppColors.primary),
                                  const SizedBox(width: 8),
                                  Text(widget.couponName!,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14)),
                                  if (widget.discountStr != null) ...[
                                    const SizedBox(width: 8),
                                    Text('-${widget.discountStr!} sats',
                                        style: const TextStyle(
                                            color: AppColors.primary,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 14)),
                                  ],
                                ],
                              ),
                            ),
                          ],
                          if (_hasPrize && !_prizeDismissed) ...[
                            const SizedBox(height: 18),
                            AnimatedBuilder(
                              animation: _prizeBeat,
                              builder: (_, child) => Opacity(
                                opacity: _prizeFade.value,
                                child: Transform.scale(
                                  scale: _prizeScale.value,
                                  child: child,
                                ),
                              ),
                              child: AnimatedBuilder(
                                animation: _prizeOut,
                                builder: (_, child) => Opacity(
                                  opacity: _prizeOutFade.value,
                                  child: Transform.scale(
                                    scale: max(0.0, _prizeOutScale.value),
                                    child: child,
                                  ),
                                ),
                                child: _PrizeGrantCard(
                                  text: widget.prizeText!,
                                  printed: widget.prizePrinted,
                                  printing: widget.printingPrize,
                                  onPrint: widget.prizePrinted ||
                                          widget.printingPrize ||
                                          widget.onPrintPrize == null
                                      ? null
                                      : _onPrintPrizeTap,
                                ),
                              ),
                            ),
                          ],
                          if (!offerWheel) ...[
                            const SizedBox(height: 28),
                            SizedBox(
                              width: 260,
                              child: FilledButton(
                                onPressed: widget.onBack,
                                child: Text(context.tr('Volver')),
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        if (offerWheel) ...[
          Positioned.fill(
            child: AnimatedBuilder(
              animation: Listenable.merge([_wheelIn, _wheelLoop]),
              builder: (context, _) {
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final h = constraints.maxHeight;
                    const buttonH = 64.0;
                    final eased = Curves.easeOutBack.transform(_wheelIn.value);
                    final travel = (1 - eased).clamp(-0.06, 1.0).toDouble();
                    final wave = sin(_wheelLoop.value * 2 * pi);
                    final restTop = (h - buttonH) / 2;
                    final maxTop = max(12.0, h - buttonH - 56);
                    final top = (restTop + h * 0.34 * travel + wave * 5)
                        .clamp(12.0, maxTop)
                        .toDouble();
                    final glow = (wave + 1) / 2;
                    return Stack(
                      children: [
                        Positioned(
                          left: 4,
                          right: 4,
                          top: top,
                          child: Transform.scale(
                            scale: 1 + wave * 0.02,
                            alignment: Alignment.center,
                            child: _SpinCue(
                              glow: glow,
                              label: context.tr('Tirar ruleta'),
                              onPressed: widget.onSpinWheel,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 2,
            child: Center(
              child: TextButton(
                onPressed: widget.onBack,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.muted,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  textStyle: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
                child: Text(context.tr('Volver')),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _SpinCue extends StatelessWidget {
  const _SpinCue({
    required this.glow,
    required this.label,
    required this.onPressed,
  });

  final double glow;
  final String label;
  final VoidCallback? onPressed;

  static const _gold = Color(0xFFD4AF37);

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: _gold.withValues(alpha: 0.25 + glow * 0.5),
            blurRadius: 14 + glow * 22,
            spreadRadius: glow * 1.5,
          ),
        ],
      ),
      child: FilledButton.icon(
        key: const Key('spin-wheel-button'),
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: _gold,
          foregroundColor: const Color(0xFF1C1C1C),
          minimumSize: const Size.fromHeight(64),
          padding: const EdgeInsets.symmetric(vertical: 16),
          textStyle:
              const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18)),
        ),
        icon: const Icon(Icons.casino_outlined, size: 28),
        label: Text(label),
      ),
    );
  }
}

class _CenterPullPainter extends CustomPainter {
  _CenterPullPainter({required this.repaint}) : super(repaint: repaint);

  final Animation<double> repaint;

  static const _colors = <Color>[
    Color(0xFFFFD166),
    Color(0xFFFFF3B0),
    Color(0xFFFFFFFF),
    Color(0xFFD4AF37),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final t = repaint.value;
    final center = Offset(size.width / 2, size.height / 2);
    final reach = max(size.width, size.height) * 0.75;
    const count = 46;
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (var i = 0; i < count; i++) {
      final angle = i * 2.399963;
      final lane = (t + i / count) % 1.0;
      final travel = lane * lane;
      final radius = reach * (1 - travel);
      final dir = Offset(cos(angle), sin(angle));
      final pos = center + dir * radius;
      final fade = sin(lane * pi);
      paint
        ..color = _colors[i % _colors.length].withValues(alpha: 0.2 + 0.75 * fade)
        ..strokeWidth = 1.4;
      canvas.drawLine(pos + dir * 14, pos, paint);
      canvas.drawCircle(pos, 1.8 + (i % 4) * 0.85, paint);
    }
  }

  @override
  bool shouldRepaint(_CenterPullPainter old) => old.repaint != repaint;
}

class _PrizeGrantCard extends StatelessWidget {
  final String text;
  final bool printed;
  final bool printing;
  final VoidCallback? onPrint;

  const _PrizeGrantCard({
    required this.text,
    required this.printed,
    required this.printing,
    required this.onPrint,
  });

  static const _gold = Color(0xFFFFD166);
  static const _goldDeep = Color(0xFFE3A008);
  static const _ink = Color(0xFF1C1C1C);

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('prize-grant-card'),
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 360),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF3A3118),
            Color(0xFF2A2414),
            AppColors.surface,
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _gold.withValues(alpha: 0.85), width: 1.6),
        boxShadow: [
          BoxShadow(
            color: _gold.withValues(alpha: 0.28),
            blurRadius: 28,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _gold.withValues(alpha: 0.18),
              border: Border.all(color: _gold, width: 1.4),
            ),
            child: const Icon(Icons.card_giftcard_rounded,
                color: _gold, size: 28),
          ),
          const SizedBox(height: 10),
          Text(context.tr('¡Ganaste un premio!'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: _gold)),
          const SizedBox(height: 8),
          Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  height: 1.2)),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('prize-print-button'),
              onPressed: onPrint,
              style: FilledButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: _ink,
                disabledBackgroundColor: printed
                    ? _goldDeep.withValues(alpha: 0.7)
                    : _gold.withValues(alpha: 0.55),
                disabledForegroundColor: _ink.withValues(alpha: 0.85),
                minimumSize: const Size.fromHeight(64),
                textStyle: const TextStyle(
                    fontFamily: 'Roboto',
                    fontSize: 20,
                    fontWeight: FontWeight.w800),
              ),
              icon: printing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.4, color: _ink),
                    )
                  : Icon(
                      printed ? Icons.check_rounded : Icons.print_rounded,
                      size: 22,
                      color: _ink.withValues(alpha: printed ? 0.85 : 1),
                    ),
              label: Text(context.tr(printed
                  ? 'Impreso'
                  : printing
                      ? 'Imprimiendo cupón…'
                      : 'Imprimir cupón')),
            ),
          ),
        ],
      ),
    );
  }
}

Path _starPath(Size size) {
  const points = 5;
  final half = size.width / 2;
  final outer = half;
  final inner = half / 2.4;
  final step = (2 * pi) / points;
  final path = Path();
  for (var i = 0; i < points; i++) {
    final outerA = -pi / 2 + i * step;
    final innerA = outerA + step / 2;
    final ox = half + outer * cos(outerA);
    final oy = half + outer * sin(outerA);
    final ix = half + inner * cos(innerA);
    final iy = half + inner * sin(innerA);
    if (i == 0) {
      path.moveTo(ox, oy);
    } else {
      path.lineTo(ox, oy);
    }
    path.lineTo(ix, iy);
  }
  path.close();
  return path;
}

/// Concentric expanding rings + a soft radial glow, driven by a 0..1 phase.
class _RipplePainter extends CustomPainter {
  final double t;
  _RipplePainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);

    // Soft glow.
    final glow = Paint()
      ..shader = RadialGradient(
        colors: [
          AppColors.primary.withValues(alpha: 0.28),
          AppColors.primary.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: size.width / 2));
    canvas.drawCircle(center, size.width / 2, glow);

    // Three staggered rings expanding outward and fading.
    for (var i = 0; i < 3; i++) {
      final phase = (t + i / 3) % 1.0;
      final radius = size.width * 0.31 + phase * size.width * 0.21;
      final opacity = (1 - phase) * 0.5;
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = AppColors.primary.withValues(alpha: opacity);
      canvas.drawCircle(center, radius, ring);
    }
  }

  @override
  bool shouldRepaint(_RipplePainter old) => old.t != t;
}

/// Draws the checkmark stroke progressively (0..1).
class _CheckPainter extends CustomPainter {
  final double progress;
  _CheckPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final paint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path()
      ..moveTo(size.width * 0.28, size.height * 0.52)
      ..lineTo(size.width * 0.44, size.height * 0.68)
      ..lineTo(size.width * 0.74, size.height * 0.34);

    final metrics = path.computeMetrics().toList();
    final total = metrics.fold<double>(0, (s, m) => s + m.length);
    var remaining = total * progress;
    final out = Path();
    for (final m in metrics) {
      if (remaining <= 0) break;
      out.addPath(m.extractPath(0, remaining.clamp(0, m.length)), Offset.zero);
      remaining -= m.length;
    }
    canvas.drawPath(out, paint);
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.progress != progress;
}
