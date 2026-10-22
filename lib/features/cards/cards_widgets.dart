import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lottie/lottie.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/theme.dart' show withButtonSound;
import '../../core/widgets.dart' show recordImage;
import 'cards_api.dart';

// Ported from card-manager's ui/theme and ui/components. The Cards miniapp
// keeps card-manager's own look (lawallet.io palette, Inter, mixed case) instead
// of the POS theme.

// ── lawallet.io palette ──────────────────────────────────────────────────────
const teal = Color(0xFF00836D);
const tealMid = Color(0xFF00A085);
const tealBright = Color(0xFF00C7A0);
const nearBlack = Color(0xFF0A0A0A);
const surface1 = Color(0xFF171717);
const surface2 = Color(0xFF262626);
const textPrimary = Color(0xFFF5F5F5);
const textSecondary = Color(0xFFA3A3A3);
const cardsError = Color(0xFFEF4444);

const tealGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [teal, tealMid, tealBright],
);

/// Inter is a variable font: the weight has to be set on its axis too.
TextStyle? _inter(TextStyle? s, [FontWeight? w]) {
  final weight = w ?? s?.fontWeight ?? FontWeight.w400;
  return s?.copyWith(
    fontFamily: 'Inter',
    fontWeight: weight,
    fontVariations: [FontVariation.weight(weight.value.toDouble())],
  );
}

ThemeData buildCardsTheme() {
  final scheme = const ColorScheme.dark(
    primary: tealBright,
    onPrimary: nearBlack,
    secondary: tealBright,
    onSecondary: nearBlack,
    tertiary: tealMid,
    surface: surface1,
    onSurface: textPrimary,
    surfaceContainerHighest: surface2,
    onSurfaceVariant: textSecondary,
    outline: surface2,
    error: cardsError,
  );
  final b = Typography.material2021(platform: TargetPlatform.android)
      .englishLike
      .merge(Typography.material2021().white);
  final text = b.copyWith(
    displayLarge: _inter(b.displayLarge),
    displayMedium: _inter(b.displayMedium),
    displaySmall: _inter(b.displaySmall),
    headlineLarge: _inter(b.headlineLarge, FontWeight.w700),
    headlineMedium: _inter(b.headlineMedium, FontWeight.w700),
    headlineSmall: _inter(b.headlineSmall, FontWeight.w600),
    titleLarge: _inter(b.titleLarge, FontWeight.w600),
    titleMedium: _inter(b.titleMedium, FontWeight.w500),
    titleSmall: _inter(b.titleSmall, FontWeight.w500),
    bodyLarge: _inter(b.bodyLarge),
    bodyMedium: _inter(b.bodyMedium),
    bodySmall: _inter(b.bodySmall),
    labelLarge: _inter(b.labelLarge, FontWeight.w500),
    labelMedium: _inter(b.labelMedium),
    labelSmall: _inter(b.labelSmall),
  );
  return withButtonSound(ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: nearBlack,
    textTheme: text,
    fontFamily: 'Inter',
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(4))),
    ),
  ));
}

/// Near-black canvas with a soft teal glow at the top — the lawallet.io feel.
class GradientBackground extends StatelessWidget {
  const GradientBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: _GlowPainter(),
        child: SizedBox.expand(child: child),
      );
}

class _GlowPainter extends CustomPainter {
  // Impeller on GLES (the Z92's PowerVR GE8300) shades a radial gradient at
  // ~75 ms per full-screen frame, and Impeller redraws it under every
  // animation. A quarter-res bitmap of the same glow, scaled up, costs ~0.
  static const _scale = 4;
  static ui.Image? _glow;
  static Size? _glowSize;

  static ui.Image _render(Size size) {
    final w = (size.width / _scale).ceil(), h = (size.height / _scale).ceil();
    return recordImage(
      w,
      h,
      (canvas) => canvas.drawRect(
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Paint()
          ..shader = ui.Gradient.radial(Offset(w / 2, h * 0.16), w * 0.95,
              [teal.withValues(alpha: 0.22), Colors.transparent]),
      ),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = nearBlack);
    if (size.isEmpty) return;
    if (_glowSize != size) {
      _glow?.dispose();
      _glow = _render(size);
      _glowSize = size;
    }
    final glow = _glow!;
    canvas.drawImageRect(
        glow,
        Rect.fromLTWH(0, 0, glow.width.toDouble(), glow.height.toDouble()),
        rect,
        Paint()..filterQuality = FilterQuality.low);
  }

  @override
  bool shouldRepaint(_GlowPainter old) => false;
}

/// Primary CTA — teal gradient fill with a teal glow.
class BrandButton extends StatelessWidget {
  const BrandButton(this.text, this.onTap,
      {super.key, this.enabled = true, this.icon});

  final String text;
  final VoidCallback onTap;
  final bool enabled;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(16);
    final tint = enabled ? textPrimary : textSecondary;
    return Container(
      height: 60,
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: enabled ? tealGradient : null,
        color: enabled ? null : surface2,
        boxShadow: enabled
            ? [
                BoxShadow(
                    color: teal.withValues(alpha: 0.55),
                    blurRadius: 20,
                    offset: const Offset(0, 8)),
              ]
            : null,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: enabled ? onTap : null,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, color: tint),
                  const SizedBox(width: 10),
                ],
                Text(text,
                    style: _inter(Theme.of(context).textTheme.titleMedium,
                            FontWeight.w600)
                        ?.copyWith(color: tint)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Secondary action — ghost/outline.
class GhostButton extends StatelessWidget {
  const GhostButton(this.text, this.onTap, {super.key, this.enabled = true});

  final String text;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(16);
    return SizedBox(
      height: 54,
      child: Material(
        type: MaterialType.transparency,
        shape: RoundedRectangleBorder(
            borderRadius: radius, side: const BorderSide(color: surface2)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Center(
            child: Text(text,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: textSecondary)),
          ),
        ),
      ),
    );
  }
}

/// Compose's `infiniteRepeatable(tween(ms), RepeatMode.Reverse)`: 0→1 eased,
/// then the same way back.
double _pingPong(Duration t, int ms, [Curve curve = Curves.fastOutSlowIn]) {
  final cycles = t.inMicroseconds / (ms * 1000);
  final u = cycles - cycles.floorToDouble();
  return curve.transform(cycles.floor().isOdd ? 1 - u : u);
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

/// A widget that rebuilds every frame with the time since it was mounted.
abstract class _TickingState<T extends StatefulWidget> extends State<T>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((t) => setState(() => elapsed = t))..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

/// A credit-card-shaped remote image that floats and rotates in real 3D
/// perspective: rotationY sweeps -16°..16° and rotationX -8°..8° on
/// out-of-phase periods, with a vertical bob, a soft drop shadow and a moving
/// sheen.
class FloatingCard extends StatefulWidget {
  const FloatingCard({super.key, required this.imageUrl});
  final String imageUrl;

  @override
  State<FloatingCard> createState() => _FloatingCardState();
}

class _FloatingCardState extends _TickingState<FloatingCard> {
  // ponytail: card-manager's cameraDistance (12 × density) is ~864 logical px
  // at any density. Lower it for more foreshortening.
  static const _cameraDistance = 864.0;

  @override
  Widget build(BuildContext context) {
    final rotY = _lerp(-16, 16, _pingPong(elapsed, 4200));
    final rotX = _lerp(-8, 8, _pingPong(elapsed, 3100));
    final bob = _lerp(-10, 10, _pingPong(elapsed, 2600));
    const radius = BorderRadius.all(Radius.circular(18));
    // Sheen slides with the tilt, as in card-manager's drawWithContent.
    final sx = rotY / 16;
    final sy = 0.7 * rotX / 8;
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..translateByDouble(0, bob, 0, 1)
        ..setEntry(3, 2, 1 / _cameraDistance)
        ..rotateX(rotX * math.pi / 180)
        ..rotateY(rotY * math.pi / 180),
      child: AspectRatio(
        aspectRatio: 1.585,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            borderRadius: radius,
            boxShadow: [
              BoxShadow(
                  color: Color(0x99000000),
                  blurRadius: 28,
                  offset: Offset(0, 14)),
            ],
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(fit: StackFit.expand, children: [
              Image.network(widget.imageUrl,
                  fit: BoxFit.cover,
                  semanticLabel: 'Card',
                  errorBuilder: (_, __, ___) => const SizedBox.shrink()),
              CustomPaint(painter: SheenPainter(sx, sy)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The card's diagonal sheen: a LinearGradient from Alignment(-1.6+sx,
/// -1.6+sy) to (1.6+sx, 1.6+sy), drawn along x in a canvas rotated onto that
/// axis. Impeller on GLES has a fast path for that (~3 ms a frame on the Z92)
/// but not for the diagonal gradient (~30 ms). Keep the band reaching past
/// the card: a tighter rect measured slow again.
class SheenPainter extends CustomPainter {
  SheenPainter(this.sx, this.sy);
  final double sx;
  final double sy;

  static final _colors = [
    Colors.transparent,
    Colors.white.withValues(alpha: 0.16),
    Colors.white.withValues(alpha: 0.30),
    Colors.white.withValues(alpha: 0.16),
    Colors.transparent,
  ];
  static const _stops = [0.0, 0.25, 0.5, 0.75, 1.0];

  @override
  void paint(Canvas canvas, Size size) {
    final begin = Alignment(-1.6 + sx, -1.6 + sy).alongSize(size);
    final axis = Alignment(1.6 + sx, 1.6 + sy).alongSize(size) - begin;
    // Past either end the gradient is transparent, so the band alone covers
    // it; the card's clip trims the rest.
    final reach = size.longestSide * 4;
    canvas
      ..translate(begin.dx, begin.dy)
      ..rotate(axis.direction)
      ..drawRect(
        Rect.fromLTRB(0, -reach, axis.distance, reach),
        Paint()
          ..shader = ui.Gradient.linear(
              Offset.zero, Offset(axis.distance, 0), _colors, _stops),
      );
  }

  @override
  bool shouldRepaint(SheenPainter old) => old.sx != sx || old.sy != sy;
}

/// Centered NFC glyph with 3 concentric "radar" rings that expand outward and
/// fade, plus a gentle scale pulse on the glyph. Signals "waiting for a tap".
class NfcPulse extends StatefulWidget {
  const NfcPulse({super.key});

  @override
  State<NfcPulse> createState() => _NfcPulseState();
}

class _NfcPulseState extends _TickingState<NfcPulse> {
  static const _ripples = 3;
  static const _rippleMs = 2400;

  @override
  Widget build(BuildContext context) {
    final ms = elapsed.inMicroseconds / 1000;
    // Each ring starts (rippleMs / count) after the previous one.
    final phases = [
      for (var i = 0; i < _ripples; i++)
        () {
          final t = ms - (_rippleMs ~/ _ripples) * i;
          return t <= 0 ? 0.0 : (t % _rippleMs) / _rippleMs;
        }(),
    ];
    final scale = _lerp(0.92, 1.08, _pingPong(elapsed, 1200));
    final color = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: 220,
      height: 220,
      child: CustomPaint(
        painter: _RingsPainter(phases, color),
        child: Center(
          child: Transform.scale(
            scale: scale,
            child:
                Icon(Icons.nfc, size: 72, color: color, semanticLabel: 'NFC'),
          ),
        ),
      ),
    );
  }
}

class _RingsPainter extends CustomPainter {
  _RingsPainter(this.phases, this.color);
  final List<double> phases;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final maxRadius = size.shortestSide / 2;
    final baseRadius = maxRadius * 0.28;
    final center = size.center(Offset.zero);
    for (final p in phases) {
      canvas.drawCircle(
        center,
        baseRadius + (maxRadius - baseRadius) * p,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = color.withValues(alpha: (1 - p).clamp(0.0, 1.0) * 0.55),
      );
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) => true;
}

/// Looping Lottie loading animation.
class LottieLoader extends StatelessWidget {
  const LottieLoader({super.key});

  @override
  Widget build(BuildContext context) =>
      Lottie.asset('assets/lottie/card_loading.json',
          width: 220, height: 220, repeat: true);
}

/// The QR as a PNG, [size] px wide with a one-module quiet zone. The ticket
/// shows it and the printer prints it, so both are the very same code.
Future<Uint8List> cardQrPng(String data, {int size = 360}) async {
  final qr = QrValidator.validate(
          data: data, errorCorrectionLevel: QrErrorCorrectLevel.L)
      .qrCode!;
  final module = size ~/ (qr.moduleCount + 2);
  final side = module * (qr.moduleCount + 2);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
      Paint()..color = Colors.white);
  canvas.translate(module.toDouble(), module.toDouble());
  QrPainter.withQr(
    qr: qr,
    gapless: true,
    eyeStyle:
        const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black),
    dataModuleStyle: const QrDataModuleStyle(
        dataModuleShape: QrDataModuleShape.square, color: Colors.black),
  ).paint(canvas, Size.square((module * qr.moduleCount).toDouble()));
  final image = await recorder.endRecording().toImage(side, side);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

/// On-screen preview of the thermal slip that gets printed: a white "paper"
/// ticket with the LaWallet header, the QR and a caption. It is the element
/// that slides up while printing.
class PrintTicket extends StatelessWidget {
  const PrintTicket(
      {super.key,
      required this.qrContent,
      required this.qrPng,
      required this.caption});

  final String qrContent;
  final Uint8List? qrPng;
  final String caption;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF0A0A0A);
    return ClipPath(
      clipper: _TornPaperClipper(),
      child: Container(
        color: const Color(0xFFFBFBF8),
        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('LaWallet',
                style: _inter(const TextStyle(color: ink, fontSize: 24),
                    FontWeight.w700)),
            const SizedBox(height: 12),
            const _DashedDivider(),
            const SizedBox(height: 18),
            FractionallySizedBox(
              widthFactor: 0.91,
              child: AspectRatio(
                aspectRatio: 1,
                child: qrPng == null
                    ? const SizedBox.shrink()
                    : Image.memory(qrPng!,
                        filterQuality: FilterQuality.none, semanticLabel: 'QR'),
              ),
            ),
            const SizedBox(height: 18),
            Text(caption.toUpperCase(),
                textAlign: TextAlign.center,
                style: _inter(
                    const TextStyle(
                        color: ink, fontSize: 13, letterSpacing: 1.2),
                    FontWeight.w600)),
            const SizedBox(height: 12),
            const _DashedDivider(),
            const SizedBox(height: 12),
            Text(cardDomain(qrContent),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Color(0xFF444444),
                    fontSize: 11,
                    fontFamily: 'monospace',
                    fontFamilyFallback: ['Courier'])),
            const SizedBox(height: 8), // small free margin
          ],
        ),
      ),
    );
  }
}

/// On-screen twin of the printed top-up slip: what was loaded and the balance
/// after it, on the same torn paper as [PrintTicket].
class TopUpTicket extends StatelessWidget {
  const TopUpTicket(
      {super.key, required this.amount, this.balance, required this.address});

  final String amount;
  final String? balance;
  final String address;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF0A0A0A);
    const faint = Color(0xFF6B6B6B);
    return ClipPath(
      clipper: _TornPaperClipper(),
      child: Container(
        color: const Color(0xFFFBFBF8),
        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('LaWallet',
                style: _inter(const TextStyle(color: ink, fontSize: 20),
                    FontWeight.w700)),
            const SizedBox(height: 10),
            const _DashedDivider(),
            const SizedBox(height: 14),
            Text('+$amount',
                style: _inter(const TextStyle(color: ink, fontSize: 30),
                    FontWeight.w800)),
            if (balance != null) ...[
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.account_balance_wallet_outlined,
                      size: 16, color: faint),
                  const SizedBox(width: 6),
                  Text(balance!,
                      style: _inter(const TextStyle(color: ink, fontSize: 16),
                          FontWeight.w600)),
                ],
              ),
            ],
            const SizedBox(height: 14),
            const _DashedDivider(),
            const SizedBox(height: 10),
            Text(address,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: faint,
                    fontSize: 11,
                    fontFamily: 'monospace',
                    fontFamilyFallback: ['Courier'])),
          ],
        ),
      ),
    );
  }
}

class _DashedDivider extends StatelessWidget {
  const _DashedDivider();

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 2,
        width: double.infinity,
        child: CustomPaint(
            painter: _DashPainter(MediaQuery.devicePixelRatioOf(context))),
      );
}

class _DashPainter extends CustomPainter {
  _DashPainter(this.dpr);
  final double dpr;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFCCCCCC)
      ..strokeWidth = size.height
      ..strokeCap = StrokeCap.round;
    final dash = 8 / dpr; // card-manager dashes are 8 device px on, 8 off
    final y = size.height / 2;
    for (var x = 0.0; x < size.width; x += dash * 2) {
      canvas.drawLine(
          Offset(x, y), Offset(math.min(x + dash, size.width), y), paint);
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => old.dpr != dpr;
}

/// Receipt-style cut paper: small triangular teeth along the top and bottom
/// edges (peaks outward), straight square sides.
class _TornPaperClipper extends CustomClipper<Path> {
  static const _tooth = 12.0; // base width of each triangle
  static const _depth = 7.0; // height of each triangle

  @override
  Path getClip(Size size) {
    final path = Path()..moveTo(0, _depth);
    var x = 0.0;
    while (x < size.width) {
      final mid = math.min(x + _tooth / 2, size.width);
      final end = math.min(x + _tooth, size.width);
      path
        ..lineTo(mid, 0)
        ..lineTo(end, _depth);
      x = end;
    }
    path.lineTo(size.width, size.height - _depth);
    var xb = size.width;
    while (xb > 0) {
      final mid = math.max(xb - _tooth / 2, 0.0);
      final end = math.max(xb - _tooth, 0.0);
      path
        ..lineTo(mid, size.height)
        ..lineTo(end, size.height - _depth);
      xb = end;
    }
    return path..close();
  }

  @override
  bool shouldReclip(_TornPaperClipper old) => false;
}

/// Portrait QR scanner with a centered square reticle and teal corner brackets.
/// Pops the scanned text, or null.
class TokenScanPage extends StatefulWidget {
  const TokenScanPage({super.key, required this.prompt});

  final String prompt;

  @override
  State<TokenScanPage> createState() => _TokenScanPageState();
}

class _TokenScanPageState extends State<TokenScanPage> {
  // The scanner owns its controller: that way it also stops the camera when
  // the app goes to the background, which a controller we pass in doesn't.
  bool _done = false;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: Stack(fit: StackFit.expand, children: [
          MobileScanner(
            onDetect: (capture) {
              final raw = capture.barcodes.firstOrNull?.rawValue;
              if (_done || raw == null) return;
              _done = true;
              Navigator.of(context).pop(raw);
            },
          ),
          const CustomPaint(painter: _SquareFramePainter()),
          Positioned(
            left: 24,
            right: 24,
            bottom: 48,
            child: Text(widget.prompt,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 14)),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
        ]),
      );
}

/// Dims everything except a centered square with teal corner brackets.
class _SquareFramePainter extends CustomPainter {
  const _SquareFramePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height) * 0.66;
    final r = Rect.fromCenter(
        center: size.center(Offset.zero), width: side, height: side);
    final mask = Paint()..color = const Color.fromARGB(150, 0, 0, 0);
    canvas
      ..drawRect(Rect.fromLTRB(0, 0, size.width, r.top), mask)
      ..drawRect(Rect.fromLTRB(0, r.top, r.left, r.bottom), mask)
      ..drawRect(Rect.fromLTRB(r.right, r.top, size.width, r.bottom), mask)
      ..drawRect(Rect.fromLTRB(0, r.bottom, size.width, size.height), mask);
    final corner = Paint()
      ..color = tealBright
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const c = 30.0;
    for (final (p, dx, dy) in [
      (r.topLeft, c, c),
      (r.topRight, -c, c),
      (r.bottomLeft, c, -c),
      (r.bottomRight, -c, -c),
    ]) {
      canvas
        ..drawLine(p, p.translate(dx, 0), corner)
        ..drawLine(p, p.translate(0, dy), corner);
    }
  }

  @override
  bool shouldRepaint(_SquareFramePainter old) => false;
}
