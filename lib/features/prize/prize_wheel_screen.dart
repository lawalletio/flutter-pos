import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:confetti/confetti.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n.dart';
import '../../core/pin_dialog.dart';
import '../../core/print_error.dart';
import '../../core/sounds.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../core/widgets.dart';
import '../../domain/config/settings_state.dart';
import '../../domain/order/order_reset.dart';
import '../../domain/order/receipt_printer.dart';
import '../../domain/prize/prize_wheel.dart';

const _prizeColors = <Color>[
  Color(0xFFFF2E63),
  Color(0xFFFFB300),
  Color(0xFF00A8F0),
  Color(0xFF8E44FF),
  Color(0xFF00C98D),
  Color(0xFFFF6A1A),
  Color(0xFFE83CD8),
  Color(0xFF1FC7B6),
];
const _missColors = <Color>[Color(0xFF2B1A52), Color(0xFF3B2772)];
const _gold = Color(0xFFFFD54A);
const _goldLight = Color(0xFFFFF4C2);
const _goldDeep = Color(0xFF9A6A0C);
const _goldInk = Color(0xFF2E1F02);
const _bronze = Color(0xFF3A2508);
const _pink = Color(0xFFFF4D8D);
const _ruby = Color(0xFFD7263D);
const _night = Color(0xFF0A0614);
const _confettiColors = <Color>[
  Color(0xFFFFD166),
  Color(0xFFFFF3B0),
  Color(0xFFFF2E63),
  Color(0xFFFFFFFF),
  Color(0xFF00C98D),
  Color(0xFF00A8F0),
];

/// Seconds before the stop when the heartbeat takes over from the casino bed.
const _kHeartbeatLead = 2.2;

/// Radians per second the wheel drifts while nobody plays.
const _kIdleDrift = 0.07;

/// Bulbs around the whole rim; only the left half is ever on screen.
const _kBulbs = 40;

/// Where the flapper sits, as a screen angle: the left edge of the wheel, so
/// the board under it reads like a written line.
const _kPointerAt = math.pi;

/// The domain measures the wheel against a pointer at the top; drawing it
/// turned by this much puts that spot under [_kPointerAt].
const _kDrawTurn = _kPointerAt + math.pi / 2;

/// Double-tap throws this hard, as a share of [kWheelMaxFlingTurns].
const _kDoubleTapThrow = 0.9;

enum _Phase { idle, dragging, coasting, spinning, settled }

enum _Hint { swipe, harder, ticker, miss, win }

enum _Lights { chase, win, dim }

/// Fortune wheel for the prize coupons, played with the finger.
///
/// The left half of a big wheel fills the screen top to bottom, axle on the
/// right edge and the flapper on the left. Dragging turns it 1:1; a release
/// faster than [kWheelMinFlingTurns], or a double tap, draws the result at
/// once and plans a throw that starts at that speed and stops on it. Slower
/// releases coast and ask for a harder throw, so the result can't be placed
/// by hand.
class PrizeWheelScreen extends StatefulWidget {
  const PrizeWheelScreen({
    super.key,
    this.coupons,
    this.singleSpin = false,
    this.returnTo,
    this.miniapp = false,
  });

  /// Coupons to draw. Defaults to the ones saved in settings.
  final List<PrizeCoupon>? coupons;

  /// One spin, then back. Used after a payment.
  final bool singleSpin;

  /// When set, back leaves the payment flow for this route instead of success.
  final String? returnTo;

  /// Rueda de la fortuna miniapp: no back, gear and X behind the PIN, prints
  /// only when the miniapp says so, and a prize resets for the next player.
  final bool miniapp;

  @override
  State<PrizeWheelScreen> createState() => _PrizeWheelScreenState();
}

class _PrizeWheelScreenState extends State<PrizeWheelScreen>
    with TickerProviderStateMixin {
  final _rng = math.Random();
  final _motion = _Motion();
  final _current = ValueNotifier<int>(0);

  late final Ticker _ticker;
  late final AnimationController _reveal;
  late final AnimationController _hand;
  late final AnimationController _shake;
  late final ConfettiController _burst;
  late final ConfettiController _rain;

  late final List<WheelSlice> _slices;
  late final List<Color> _colors;
  late final List<(double, double)> _arcs;
  late final List<double> _pegs;
  late final double _reach;
  var _built = false;

  _Geo? _geo;
  _Art? _art;

  var _phase = _Phase.idle;
  var _hint = _Hint.swipe;

  /// Seconds of motion so far. Frames longer than 50 ms count as 50 ms, so a
  /// paused route doesn't jump a throw ahead when it comes back.
  double _clock = 0;
  double _lastElapsed = 0;
  double _lastU = 0;
  int _dir = 1;
  double _springAt = -1;
  double _lastTickAt = -1;
  double _speed = 0;
  double _beatFrom = -1;

  int? _finger;
  final _samples = <(Duration, double)>[];
  double _fingerRaw = 0;
  double _fingerTurned = 0;
  double _grabWheel = 0;
  Offset _downAt = Offset.zero;
  Duration _downTime = Duration.zero;
  double _travel = 0;
  Duration? _lastTapAt;
  Offset _lastTapPos = Offset.zero;

  WheelThrow? _throw;
  double _throwAt = 0;
  int _target = 0;
  double _coast = 0;
  double _harderUntil = 0;
  bool _spun = false;

  bool _printing = false;
  bool _printed = false;
  bool _printGate = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _reveal = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _hand = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1900),
    );
    _shake = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    _burst = ConfettiController(duration: const Duration(milliseconds: 1600));
    _rain = ConfettiController(duration: const Duration(milliseconds: 2800));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_built) return;
    final coupons = widget.coupons ?? appSettings.value.prizeCoupons;
    _slices = distributeWheelSlices(buildWheelSlices(
      coupons,
      keepPlayingLabel: context.tr('Seguí participando'),
    ));
    final byId = <String, Color>{};
    var misses = 0;
    _colors = [
      for (final slice in _slices)
        slice.isPrize
            ? byId.putIfAbsent(
                slice.id, () => _prizeColors[byId.length % _prizeColors.length])
            : _missColors[misses++ % _missColors.length],
    ];
    final total = wheelWeight(_slices);
    _pegs = [for (var i = 0; i < _slices.length; i++) sliceStart(_slices, i)];
    _arcs = [
      for (var i = 0; i < _slices.length; i++)
        (
          -math.pi / 2 + _pegs[i] * 2 * math.pi,
          _slices[i].weight / total * 2 * math.pi,
        ),
    ];
    final thinnest = _slices.map((s) => s.weight).reduce(math.min) / total;
    _reach = (thinnest * 0.2).clamp(0.003, 0.012);
    _built = true;
    _syncHand();
  }

  @override
  void dispose() {
    _stopBeds();
    _ticker.dispose();
    _reveal.dispose();
    _hand.dispose();
    _shake.dispose();
    _burst.dispose();
    _rain.dispose();
    _motion.dispose();
    _current.dispose();
    _art?.dispose();
    super.dispose();
  }

  bool get _hasPrizes => _slices.any((slice) => slice.isPrize);

  bool get _canThrow {
    if (!_hasPrizes || _printGate) return false;
    return switch (_phase) {
      _Phase.idle || _Phase.coasting => true,
      _Phase.settled => !widget.singleSpin && !_slices[_target].isPrize,
      _Phase.dragging || _Phase.spinning => false,
    };
  }

  bool get _showHand =>
      _canThrow && _phase != _Phase.coasting && _hint != _Hint.harder;

  /// The swipe hint only animates while it is on screen.
  void _syncHand() {
    if (_showHand) {
      if (!_hand.isAnimating) _hand.repeat();
    } else if (_hand.isAnimating) {
      _hand.stop();
    }
  }

  // ---------------------------------------------------------------- motion

  void _onTick(Duration elapsed) {
    final now = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final dt = (now - _lastElapsed).clamp(0.0, 0.05);
    _lastElapsed = now;
    _clock += dt;
    final m = _motion;
    final before = m.angle;
    switch (_phase) {
      case _Phase.idle:
        m.angle += _kIdleDrift * dt;
      case _Phase.coasting:
        m.angle += _coast * dt;
        _coast *= math.exp(-dt / 0.5);
      case _Phase.spinning:
        final plan = _throw!;
        final at = _clock - _throwAt;
        m.angle = plan.angleAt(at);
        if (_beatFrom < 0 && plan.seconds - at <= _kHeartbeatLead) {
          _startHeartbeat();
        }
      case _Phase.dragging:
      case _Phase.settled:
        break;
    }
    if (dt > 0) _speed += ((m.angle - before).abs() / dt - _speed) * 0.25;
    _follow();
    m.lights += dt *
        switch (m.mode) {
          _Lights.chase => 0.45 + math.min(_speed / (2 * math.pi), 4) * 1.2,
          _Lights.win => 2.4,
          _Lights.dim => 0.35,
        };
    m.rays += dt * (0.035 + math.min(_speed, 25) * 0.004);
    m.beat = _beatFrom < 0
        ? 0
        : math.pow(math.max(0, math.sin((_clock - _beatFrom) * math.pi / 0.36)), 2)
            .toDouble();
    if (m.glowIndex >= 0) {
      m.glow = m.mode == _Lights.win
          ? 0.55 + 0.45 * math.sin(_clock * math.pi * 3)
          : 0.35;
    }
    m.frame();

    if (_phase == _Phase.spinning && _clock - _throwAt >= _throw!.seconds) {
      _settle();
    } else if (_phase == _Phase.coasting && _coast.abs() < 0.04) {
      setState(() => _phase = _Phase.idle);
      _syncHand();
    }
    if (_hint == _Hint.harder &&
        _clock > _harderUntil &&
        _phase != _Phase.dragging) {
      setState(() => _hint = _Hint.swipe);
      _syncHand();
    }
  }

  /// Pegs, flapper, tick and the caption, from however the wheel moved.
  void _follow() {
    final u = -_motion.angle / (2 * math.pi);
    final du = u - _lastU;
    var crossed = 0;
    if (du != 0) {
      _dir = du > 0 ? 1 : -1;
      final lo = math.min(_lastU, u);
      final hi = math.max(_lastU, u);
      for (final peg in _pegs) {
        crossed += (hi - peg).floor() - (lo - peg).floor();
      }
    }
    _lastU = u;
    final frac = u - u.floorToDouble();
    var gap = 1.0;
    for (final peg in _pegs) {
      final d = _dir > 0 ? (peg - frac) % 1 : (frac - peg) % 1;
      if (d < gap) gap = d;
    }
    if (crossed > 0) {
      _springAt = _clock;
      if (_clock - _lastTickAt >= 0.045) {
        _lastTickAt = _clock;
        AppSounds.play(AppSound.tick);
      }
    }
    // The next peg leans the flapper over; once it slips past, the flapper
    // snaps back and rings out.
    final push = (1 - gap / _reach).clamp(0.0, 1.0);
    final since = _clock - _springAt;
    final spring = _springAt < 0 || since > 0.6
        ? 0.0
        : math.exp(-since / 0.075) * math.cos(since * 2 * math.pi / 0.13);
    _motion.flap = _dir * 0.42 * (push >= spring.abs() ? push : spring);
    final index = sliceIndexAt(_slices, frac);
    if (index != _current.value) _current.value = index;
  }

  // ---------------------------------------------------------------- finger

  void _down(PointerDownEvent e) {
    final g = _geo;
    if (g == null || _finger != null || !_canThrow) return;
    final rel = e.localPosition - g.center;
    if (rel.distance > g.outer * 1.12 || rel.distance < g.hub * 0.6) return;
    _finger = e.pointer;
    _fingerRaw = math.atan2(rel.dy, rel.dx);
    _fingerTurned = 0;
    _grabWheel = _motion.angle;
    _downAt = e.localPosition;
    _downTime = e.timeStamp;
    _travel = 0;
    _samples
      ..clear()
      ..add((e.timeStamp, 0));
    _coast = 0;
    _clearResult();
    setState(() {
      _phase = _Phase.dragging;
      if (_hint != _Hint.harder) _hint = _Hint.swipe;
    });
    _syncHand();
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _finger) return;
    final rel = e.localPosition - _geo!.center;
    // Right over the axle the angle jumps around; just wait for the finger.
    if (rel.distance < _geo!.hub * 0.4) return;
    final raw = math.atan2(rel.dy, rel.dx);
    var step = raw - _fingerRaw;
    if (step > math.pi) step -= 2 * math.pi;
    if (step < -math.pi) step += 2 * math.pi;
    _fingerRaw = raw;
    _fingerTurned += step;
    _motion.angle = _grabWheel + _fingerTurned;
    _travel = math.max(_travel, (e.localPosition - _downAt).distance);
    _samples.add((e.timeStamp, _fingerTurned));
    while (_samples.length > 2 &&
        e.timeStamp - _samples.first.$1 > const Duration(milliseconds: 200)) {
      _samples.removeAt(0);
    }
  }

  void _up(PointerUpEvent e) {
    if (e.pointer != _finger) return;
    _finger = null;
    final tap = _travel < 18 &&
        e.timeStamp - _downTime < const Duration(milliseconds: 300);
    if (tap) {
      final last = _lastTapAt;
      final twice = last != null &&
          _downTime - last < const Duration(milliseconds: 350) &&
          (e.localPosition - _lastTapPos).distance < 80;
      _lastTapAt = twice ? null : e.timeStamp;
      _lastTapPos = e.localPosition;
      if (twice) {
        _launch(kWheelMaxFlingTurns *
            2 *
            math.pi *
            (_kDoubleTapThrow + 0.1 * _rng.nextDouble()));
        return;
      }
    }
    _release(_flingSpeed(e.timeStamp));
  }

  void _cancel(PointerCancelEvent e) {
    if (e.pointer != _finger) return;
    _finger = null;
    _release(0);
  }

  /// Radians per second over the last moves, timed by the touch events
  /// themselves, so a slow frame on the till can't eat the throw.
  double _flingSpeed(Duration upAt) {
    if (_samples.length < 2) return 0;
    final (lastAt, last) = _samples.last;
    // A finger that rested before lifting has no speed left to give.
    if (upAt - lastAt > const Duration(milliseconds: 80)) return 0;
    var i = _samples.length - 2;
    while (i > 0 && lastAt - _samples[i].$1 < const Duration(milliseconds: 80)) {
      i--;
    }
    final (firstAt, first) = _samples[i];
    final seconds =
        (lastAt - firstAt).inMicroseconds / Duration.microsecondsPerSecond;
    return seconds < 0.008 ? 0 : (last - first) / seconds;
  }

  void _release(double velocity) {
    if (wheelFlingCounts(velocity)) {
      _launch(velocity);
      return;
    }
    final tried = _fingerTurned.abs() > 0.12 || velocity.abs() > 0.6;
    _coast = velocity;
    setState(() {
      _phase = _Phase.coasting;
      if (tried) _hint = _Hint.harder;
    });
    if (tried) {
      _harderUntil = _clock + 1.8;
      _shake.forward(from: 0);
      HapticFeedback.lightImpact();
    }
    _syncHand();
  }

  /// Screen readers can't fling, so a tap throws at a fair random speed.
  void _autoSpin() {
    if (!_canThrow) return;
    _clearResult();
    _launch(kWheelMinFlingTurns * 2 * math.pi * (1.8 + _rng.nextDouble() * 1.5));
  }

  /// The result is drawn here, before the wheel moves.
  void _launch(double velocity) {
    final settings = appSettings.value;
    _target = pickSliceIndex(_slices, _rng.nextDouble());
    _throw = planWheelThrow(
      angle: _motion.angle,
      velocity: velocity,
      target: landingFraction(_slices, _target, 0.2 + 0.6 * _rng.nextDouble()),
      durationMs: settings.wheelDurationMs,
      speed: settings.wheelSpeed,
      acceleration: settings.wheelAcceleration,
    );
    _throwAt = _clock;
    _spun = true;
    _printing = false;
    _printed = false;
    _beatFrom = -1;
    AppSounds.stop(AppSound.heartbeat);
    AppSounds.stop(AppSound.win);
    AppSounds.stop(AppSound.miss);
    AppSounds.play(AppSound.casino, loop: true);
    HapticFeedback.mediumImpact();
    setState(() {
      _phase = _Phase.spinning;
      _hint = _Hint.ticker;
    });
    _syncHand();
  }

  void _clearResult() {
    _burst.stop();
    _rain.stop();
    _reveal.value = 0;
    _motion
      ..mode = _Lights.chase
      ..glowIndex = -1
      ..glow = 0;
  }

  void _startHeartbeat() {
    _beatFrom = _clock;
    AppSounds.stop(AppSound.casino);
    AppSounds.play(AppSound.heartbeat, loop: true);
    HapticFeedback.mediumImpact();
  }

  void _stopBeds() {
    AppSounds.stop(AppSound.casino);
    AppSounds.stop(AppSound.heartbeat);
    AppSounds.stop(AppSound.miss);
    _beatFrom = -1;
  }

  void _settle() {
    final plan = _throw!;
    _motion.angle = plan.angleAt(plan.seconds);
    _follow();
    _current.value = _target;
    final slice = _slices[_target];
    final printTicket = !widget.miniapp || appSettings.value.wheelPracticePrint;
    _stopBeds();
    _motion
      ..glowIndex = _target
      ..mode = slice.isPrize ? _Lights.win : _Lights.dim;
    setState(() {
      _phase = _Phase.settled;
      _hint = slice.isPrize ? _Hint.win : _Hint.miss;
      _printing = slice.isPrize && printTicket;
      _printed = slice.isPrize && !printTicket;
    });
    _syncHand();
    _reveal.forward(from: 0);
    if (!slice.isPrize) {
      AppSounds.play(AppSound.miss);
      HapticFeedback.mediumImpact();
      return;
    }
    AppSounds.play(AppSound.win);
    HapticFeedback.heavyImpact();
    _burst.play();
    _rain.play();
    if (printTicket) _claim();
  }

  Future<void> _claim() async {
    final prize = _slices[_target].prize;
    if (prize == null || _printed || _printGate) return;
    setState(() {
      _printing = true;
      _printGate = true;
    });
    final printed = await printOrAskToContinue(
      context,
      print: () => printPrizeCoupon(text: prize.text),
    );
    if (!mounted) return;
    setState(() {
      _printing = false;
      _printed = printed;
      _printGate = false;
    });
    if (!printed) _leave();
  }

  void _leave() {
    if (_printGate) return;
    AppSounds.stop(AppSound.win);
    AppSounds.stop(AppSound.miss);
    if (widget.miniapp) {
      _clearResult();
      setState(() {
        _phase = _Phase.idle;
        _hint = _Hint.swipe;
      });
      _syncHand();
      return;
    }
    final destination = widget.returnTo;
    if (destination == null || destination.isEmpty) {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/hub');
      }
      return;
    }
    resetOrder();
    context.go(destination);
  }

  // ---------------------------------------------------------------- chrome

  PreferredSizeWidget _bar({required bool leavePayment}) {
    if (!widget.miniapp) {
      return PosAppBar(
        title: context.tr('Ruleta'),
        showSettings: false,
        onBack: leavePayment ? _leave : null,
      );
    }
    final busy = _phase == _Phase.spinning || _printGate;
    return PosAppBar(
      title: context.tr('Rueda de la fortuna'),
      showBack: false,
      showSettings: false,
      showSync: false,
      showInvoiceDebug: false,
      actions: [
        IconButton(
          key: const Key('rueda-config'),
          icon: const Icon(Icons.settings_outlined, size: 28),
          onPressed: busy ? null : _openConfig,
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: IconButton(
            key: const Key('miniapp-close'),
            icon: const Icon(Icons.close, size: 30),
            onPressed: busy ? null : _close,
          ),
        ),
      ],
    );
  }

  Future<void> _openConfig() async {
    if (await confirmMiniappPin(context, action: 'Entrar') && mounted) {
      context.push('/rueda/config');
    }
  }

  Future<void> _close() async {
    if (await confirmMiniappPin(context, action: 'Salir') && mounted) {
      context.go('/');
    }
  }

  @override
  Widget build(BuildContext context) {
    final leavePayment = widget.returnTo != null && widget.returnTo!.isNotEmpty;
    return PopScope(
      canPop: !widget.miniapp && !leavePayment && !_printGate,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        backgroundColor: _night,
        appBar: _bar(leavePayment: leavePayment),
        body: _hasPrizes
            ? LayoutBuilder(
                builder: (context, box) => _game(context, box.biggest))
            : const _NoPrizes(),
      ),
    );
  }

  Widget _game(BuildContext context, Size size) {
    final geo = _Geo(size);
    _geo = geo;
    // ponytail: 2x is plenty for a wheel that is usually moving; raise it if
    // a still wheel looks soft on a dense screen.
    final dpr = math.min(MediaQuery.devicePixelRatioOf(context), 2.0);
    var art = _art;
    if (art == null || art.geo != geo || art.dpr != dpr) {
      art?.dispose();
      art = _art = _Art.paint(geo, dpr, _slices, _colors);
    }
    final won = _phase == _Phase.settled && _slices[_target].isPrize;
    return Stack(
      fit: StackFit.expand,
      children: [
        RawImage(image: art.backdrop, fit: BoxFit.fill),
        ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                child: CustomPaint(
                  painter: _DiscPainter(motion: _motion, art: art, arcs: _arcs),
                ),
              ),
              RawImage(image: art.frame, fit: BoxFit.fill),
              RepaintBoundary(
                child: CustomPaint(
                  painter: _RimPainter(motion: _motion, art: art),
                ),
              ),
            ],
          ),
        ),
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: _showHand ? 1 : 0,
            duration: const Duration(milliseconds: 260),
            child: Stack(
              fit: StackFit.expand,
              children: [
                RepaintBoundary(
                    child: CustomPaint(painter: _SwipeArcPainter(geo))),
                _SwipeHand(geo: geo, animation: _hand),
              ],
            ),
          ),
        ),
        Semantics(
          button: true,
          label: context.tr('Rueda de la fortuna'),
          hint: context.tr('Deslizá fuerte o tocá dos veces'),
          onTap: _canThrow ? _autoSpin : null,
          onTapHint: context.tr('Girar'),
          child: Listener(
            key: const Key('wheel-input'),
            behavior: HitTestBehavior.opaque,
            onPointerDown: _down,
            onPointerMove: _move,
            onPointerUp: _up,
            onPointerCancel: _cancel,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: geo.band,
          child: _panel(context, geo.band),
        ),
        IgnorePointer(
          child: Align(
            alignment: const Alignment(0, -0.2),
            child: ConfettiWidget(
              confettiController: _burst,
              canvas: size,
              blastDirectionality: BlastDirectionality.explosive,
              numberOfParticles: 48,
              maxBlastForce: 42,
              minBlastForce: 18,
              gravity: 0.18,
              emissionFrequency: 0.05,
              colors: _confettiColors,
              createParticlePath: _confettiBit,
            ),
          ),
        ),
        IgnorePointer(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConfettiWidget(
              confettiController: _rain,
              canvas: size,
              blastDirection: math.pi / 2,
              emissionFrequency: 0.05,
              numberOfParticles: 14,
              gravity: 0.22,
              maxBlastForce: 22,
              minBlastForce: 8,
              colors: _confettiColors,
            ),
          ),
        ),
        if (won)
          _PrizeReveal(
            animation: _reveal,
            name: _slices[_target].label,
            color: _colors[_target],
            printing: _printing,
            onTap: _leave,
          ),
      ],
    );
  }

  Widget _panel(BuildContext context, double height) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (height >= 150) ...[
            Text(
              context.tr('¡Girá y ganá!'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'ClimateCrisis',
                fontSize: 32,
                color: _gold,
                shadows: [
                  Shadow(color: Color(0xAAFF8A00), blurRadius: 22),
                  Shadow(color: Color(0xFF5A3A00), offset: Offset(0, 3)),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
          SizedBox(
            height: 84,
            child: RepaintBoundary(
              // The display font, or a big system text size, can be taller
              // than the band: the message shrinks to fit instead.
              child: LayoutBuilder(
                builder: (context, box) => FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SizedBox(
                    width: box.maxWidth,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 260),
                      switchInCurve: Curves.easeOutBack,
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: ScaleTransition(
                          scale:
                              Tween(begin: 0.9, end: 1.0).animate(animation),
                          child: child,
                        ),
                      ),
                      child: _status(context),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _status(BuildContext context) {
    final again = _spun && _canThrow;
    return switch (_hint) {
      _Hint.swipe => _StatusLine(
          key: ValueKey('swipe-$again'),
          text: context.tr(again
              ? 'Deslizá para girar otra vez'
              : 'Deslizá fuerte o tocá dos veces'),
        ),
      _Hint.harder => _Harder(key: const ValueKey('harder'), shake: _shake),
      _Hint.ticker => ValueListenableBuilder<int>(
          key: const ValueKey('ticker'),
          valueListenable: _current,
          builder: (context, index, _) =>
              _Ticker(label: _slices[index].label, color: _colors[index]),
        ),
      _Hint.miss => _Miss(
          key: const ValueKey('miss'),
          again: again,
          onContinue: widget.singleSpin ? _leave : null,
        ),
      _Hint.win => _Ticker(
          key: const ValueKey('win'),
          label: _slices[_target].label,
          color: _colors[_target],
          won: true,
        ),
    };
  }
}

/// What every frame reads. Painters listen to it, so a frame repaints two
/// canvases and rebuilds nothing.
class _Motion extends ChangeNotifier {
  double angle = 0;
  double flap = 0;
  double rays = 0;
  double lights = 0;
  double beat = 0;
  double glow = 0;
  int glowIndex = -1;
  _Lights mode = _Lights.chase;

  void frame() => notifyListeners();
}

/// The left half of the wheel: axle on the right edge, a band on top for the
/// messages, everything sized from [outer].
class _Geo {
  factory _Geo(Size size) {
    final outer = math.min(size.width * 0.9, size.height * 0.46);
    final band = math.max(96.0, size.height - 2 * outer);
    return _Geo._(size, outer, band);
  }

  _Geo._(this.size, this.outer, this.band)
      : center = Offset(size.width, band + outer);

  final Size size;
  final Offset center;
  final double outer;
  final double band;

  double get disc => outer * 0.915;
  double get hub => outer * 0.16;
  double get ring => (outer + disc) / 2;
  double get bulb => (outer - disc) * 0.21;
  double get peg => outer * 0.013;
  double get pegRing => disc - outer * 0.032;
  double get labelOuter => disc - outer * 0.072;
  double get labelInner => hub + outer * 0.05;
  double get cap => outer * 0.072;
  double get pointerLength => outer * 0.17;
  Offset get pivot => center + _dir(_kPointerAt) * (outer - outer * 0.012);

  @override
  bool operator ==(Object other) =>
      other is _Geo && other.size == size && other.outer == outer;

  @override
  int get hashCode => Object.hash(size, outer);
}

Offset _dir(double angle) => Offset(math.cos(angle), math.sin(angle));

bool _offscreen(Offset at, Size size, double pad) =>
    at.dx < -pad ||
    at.dy < -pad ||
    at.dx > size.width + pad ||
    at.dy > size.height + pad;

/// The wheel's art, moving and fixed, rasterized once per size. A frame is
/// then a few image draws instead of paths, gradients and text.
class _Art {
  _Art._(this.geo, this.dpr, this.disc, this.rays, this.bulb, this.pointer,
      this.pointerRect, this.backdrop, this.frame);

  factory _Art.paint(
      _Geo geo, double dpr, List<WheelSlice> slices, List<Color> colors) {
    final (pointer, pointerRect) = _paintPointer(geo, dpr);
    return _Art._(
      geo,
      dpr,
      _paintDisc(geo, dpr, slices, colors),
      _paintRays(geo),
      _paintBulb(geo, dpr),
      pointer,
      pointerRect,
      _bake(geo, dpr, _BackdropPainter(geo)),
      _bake(geo, dpr, _FramePainter(geo)),
    );
  }

  final _Geo geo;
  final double dpr;
  final ui.Image disc;
  final ui.Image rays;
  final ui.Image bulb;
  final ui.Image pointer;
  final Rect pointerRect;
  final ui.Image backdrop;
  final ui.Image frame;

  double get raysRadius => geo.outer * 1.9;

  void dispose() {
    disc.dispose();
    rays.dispose();
    bulb.dispose();
    pointer.dispose();
    backdrop.dispose();
    frame.dispose();
  }
}

/// [painter] over the whole screen, once. Impeller has no raster cache, so
/// its radial, sweep and diagonal gradients were re-shaded every frame; on
/// the Z92's GPU that alone held the wheel to ~5 fps.
ui.Image _bake(_Geo g, double dpr, CustomPainter painter) {
  final size = g.size;
  return recordImage((size.width * dpr).ceil(), (size.height * dpr).ceil(),
      (canvas) {
    canvas.scale(dpr);
    painter.paint(canvas, size);
  });
}

Color _shade(Color color, double amount) => amount < 0
    ? Color.lerp(color, Colors.black, -amount)!
    : Color.lerp(color, Colors.white, amount)!;

ui.Image _paintDisc(
    _Geo g, double dpr, List<WheelSlice> slices, List<Color> colors) {
  final r = g.disc;
  final px = (2 * r * dpr).ceil();
  return recordImage(px, px, (canvas) {
    canvas.scale(px / (2 * r));
    canvas.translate(r, r);
    final bounds = Rect.fromCircle(center: Offset.zero, radius: r);
    final total = wheelWeight(slices);
    final starts = <double>[];
    var start = -math.pi / 2;
    for (var i = 0; i < slices.length; i++) {
      final sweep = slices[i].weight / total * 2 * math.pi;
      starts.add(start);
      final base = colors[i];
      canvas.drawPath(
        Path()
          ..moveTo(0, 0)
          ..arcTo(bounds, start, sweep, false)
          ..close(),
        Paint()
          ..shader = RadialGradient(
            colors: [
              _shade(base, -0.5),
              _shade(base, -0.12),
              base,
              _shade(base, 0.16),
            ],
            stops: const [0.12, 0.55, 0.86, 1],
          ).createShader(bounds),
      );
      start += sweep;
    }
    for (var i = 0; i < slices.length; i++) {
      final sweep = slices[i].weight / total * 2 * math.pi;
      _paintLabel(canvas, g, slices[i].label, starts[i] + sweep / 2, sweep);
    }
    final shadow = Paint()
      ..color = const Color(0x80000000)
      ..strokeWidth = r * 0.016;
    final line = Paint()
      ..color = const Color(0xE6FFF1C4)
      ..strokeWidth = r * 0.006;
    for (final a in starts) {
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(dir * g.hub, dir * r, shadow);
      canvas.drawLine(dir * g.hub, dir * r, line);
    }
    canvas.drawCircle(
      Offset.zero,
      r - r * 0.004,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.008
        ..color = const Color(0x8C000000),
    );
    final pegShadow = Paint()..color = const Color(0xA6000000);
    for (final a in starts) {
      final at = Offset(math.cos(a), math.sin(a)) * g.pegRing;
      final dome = Rect.fromCircle(center: at, radius: g.peg);
      canvas.drawCircle(at, g.peg * 1.45, pegShadow);
      canvas.drawCircle(
        at,
        g.peg,
        Paint()
          ..shader = const RadialGradient(
            colors: [_goldLight, _gold, _goldDeep],
            stops: [0, 0.45, 1],
          ).createShader(dome),
      );
    }
  });
}

/// The prize name runs along its board, from the rim toward the axle, as big
/// as the board allows.
void _paintLabel(Canvas canvas, _Geo g, String raw, double mid, double sweep) {
  final text = raw.replaceAll('\n', ' ').trim().toUpperCase();
  if (text.isEmpty) return;
  final length = g.labelOuter - g.labelInner;
  final half = math.min(sweep, math.pi) / 2;
  final biggest = math.min(34.0, g.outer * 0.105).floorToDouble();
  for (var size = biggest; size >= 10; size--) {
    for (final lines in const [1, 2]) {
      final last = size <= 10 && lines == 2;
      final fill = _labelPainter(text, size, lines, last, length, stroke: false);
      if (fill.didExceedMaxLines && !last) {
        fill.dispose();
        continue;
      }
      // The board narrows toward the axle, so the end of the text is the
      // tightest spot.
      final end = g.labelOuter - fill.width;
      final room = 2 * end * math.sin(half) * 0.84;
      if (fill.height > room) {
        fill.dispose();
        continue;
      }
      final stroke = _labelPainter(text, size, lines, last, length, stroke: true);
      canvas.save();
      canvas.rotate(mid + math.pi);
      final at = Offset(-g.labelOuter, -fill.height / 2);
      stroke.paint(canvas, at);
      fill.paint(canvas, at);
      canvas.restore();
      fill.dispose();
      stroke.dispose();
      return;
    }
  }
}

TextPainter _labelPainter(
  String text,
  double size,
  int lines,
  bool ellipsis,
  double width, {
  required bool stroke,
}) {
  return TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontSize: size,
        fontWeight: FontWeight.w900,
        height: 1.0,
        letterSpacing: size * 0.04,
        color: stroke ? null : Colors.white,
        foreground: stroke
            ? (Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = size * 0.17
              ..strokeJoin = StrokeJoin.round
              ..color = const Color(0xB3000000))
            : null,
      ),
    ),
    textDirection: TextDirection.ltr,
    textWidthBasis: TextWidthBasis.longestLine,
    maxLines: lines,
    ellipsis: ellipsis ? '…' : null,
  )..layout(maxWidth: width);
}

/// Soft rays behind the wheel plus its drop shadow. Rays are blurry, so they
/// are rendered at half a pixel per point and scaled up.
ui.Image _paintRays(_Geo g) {
  final r = g.outer * 1.9;
  final px = math.max(64, r.ceil());
  return recordImage(px, px, (canvas) {
    canvas.scale(px / (2 * r));
    canvas.translate(r, r);
    final bounds = Rect.fromCircle(center: Offset.zero, radius: r);
    const count = 18;
    final rays = Path();
    for (var i = 0; i < count; i++) {
      rays
        ..moveTo(0, 0)
        ..arcTo(bounds, i * 2 * math.pi / count, math.pi / count, false)
        ..close();
    }
    final inner = g.outer / r;
    canvas.drawPath(
      rays,
      Paint()
        ..shader = RadialGradient(
          colors: const [Color(0x00FFD54A), Color(0x38FFD54A), Color(0x00FFD54A)],
          stops: [inner * 0.95, inner * 1.12, 1],
        ).createShader(bounds),
    );
    canvas.drawCircle(
      Offset.zero,
      g.outer * 1.02,
      Paint()
        ..color = const Color(0xB3000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, g.outer * 0.05),
    );
  });
}

ui.Image _paintBulb(_Geo g, double dpr) {
  final r = g.bulb * 2.8;
  final px = math.max(8, (2 * r * dpr).ceil());
  return recordImage(px, px, (canvas) {
    canvas.scale(px / (2 * r));
    canvas.translate(r, r);
    canvas.drawCircle(
      Offset.zero,
      r,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0x99FFE27A), Color(0x00FFB300)],
          stops: [0.2, 1],
        ).createShader(Rect.fromCircle(center: Offset.zero, radius: r)),
    );
    canvas.drawCircle(
      Offset.zero,
      g.bulb,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.3, -0.35),
          colors: [Colors.white, _goldLight, Color(0xFFFFC52E)],
          stops: [0, 0.4, 1],
        ).createShader(Rect.fromCircle(center: Offset.zero, radius: g.bulb)),
    );
  });
}

Path _flapperPath(double cap, double length) => Path()
  ..moveTo(0, length)
  ..cubicTo(cap * 0.3, length * 0.72, cap * 1.02, length * 0.38, cap, 0)
  ..arcTo(Rect.fromCircle(center: Offset.zero, radius: cap), 0, -math.pi,
      false)
  ..cubicTo(-cap * 1.02, length * 0.38, -cap * 0.3, length * 0.72, 0, length)
  ..close();

/// The flapper, pivot at the origin and tip pointing down.
(ui.Image, Rect) _paintPointer(_Geo g, double dpr) {
  final cap = g.cap;
  final length = g.pointerLength;
  final pad = cap * 0.7;
  final rect = Rect.fromLTRB(-cap - pad, -cap - pad, cap + pad, length + pad);
  final image = recordImage(
    (rect.width * dpr).ceil(),
    (rect.height * dpr).ceil(),
    (canvas) {
      canvas.scale(dpr);
      canvas.translate(-rect.left, -rect.top);
      final body = _flapperPath(cap, length);
      canvas.drawPath(
        body.shift(Offset(cap * 0.12, cap * 0.25)),
        Paint()
          ..color = const Color(0x99000000)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, cap * 0.2),
      );
      canvas.drawPath(
        body,
        Paint()
          ..shader = const LinearGradient(
            colors: [_goldDeep, _goldLight, _gold, _goldDeep],
            stops: [0, 0.35, 0.62, 1],
          ).createShader(Rect.fromLTRB(-cap, -cap, cap, length)),
      );
      canvas.drawPath(
        body,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = cap * 0.07
          ..color = _bronze,
      );
      canvas.drawPath(
        _flapperPath(cap * 0.5, length * 0.8).shift(Offset(0, cap * 0.3)),
        Paint()
          ..shader = const LinearGradient(
            colors: [Color(0xFF8E0F22), Color(0xFFFF5A6E), _ruby],
            stops: [0, 0.4, 1],
          ).createShader(Rect.fromLTRB(-cap / 2, 0, cap / 2, length)),
      );
      canvas.drawCircle(Offset.zero, cap * 0.46, Paint()..color = _bronze);
      canvas.drawCircle(
        Offset.zero,
        cap * 0.36,
        Paint()
          ..shader = const RadialGradient(
            center: Alignment(-0.35, -0.4),
            colors: [Colors.white, _pink, _ruby],
            stops: [0, 0.35, 1],
          ).createShader(
              Rect.fromCircle(center: Offset.zero, radius: cap * 0.36)),
      );
    },
  );
  return (image, rect);
}

class _BackdropPainter extends CustomPainter {
  const _BackdropPainter(this.geo);

  final _Geo geo;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.background, Color(0xFF170B30), _night],
          stops: [0, 0.4, 1],
        ).createShader(rect),
    );
    final glow = Rect.fromCircle(center: geo.center, radius: geo.outer * 1.7);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0x664B1F9A), Color(0x00000000)],
        ).createShader(glow),
    );
  }

  @override
  bool shouldRepaint(covariant _BackdropPainter oldDelegate) =>
      oldDelegate.geo != geo;
}

class _DiscPainter extends CustomPainter {
  _DiscPainter({required this.motion, required this.art, required this.arcs})
      : super(repaint: motion);

  final _Motion motion;
  final _Art art;
  final List<(double, double)> arcs;
  final _disc = Paint()..filterQuality = FilterQuality.medium;
  final _rays = Paint()..filterQuality = FilterQuality.low;
  final _glow = Paint()..blendMode = BlendMode.plus;

  @override
  void paint(Canvas canvas, Size size) {
    final g = art.geo;
    canvas.save();
    canvas.translate(g.center.dx, g.center.dy);
    canvas.save();
    canvas.rotate(motion.rays);
    canvas.drawImageRect(
      art.rays,
      _whole(art.rays),
      Rect.fromCircle(center: Offset.zero, radius: art.raysRadius),
      _rays,
    );
    canvas.restore();
    canvas.rotate(motion.angle + _kDrawTurn);
    final disc = Rect.fromCircle(center: Offset.zero, radius: g.disc);
    canvas.drawImageRect(art.disc, _whole(art.disc), disc, _disc);
    if (motion.glowIndex >= 0 && motion.glow > 0) {
      final (start, sweep) = arcs[motion.glowIndex];
      _glow.color = Color.fromRGBO(255, 236, 190, 0.3 * motion.glow);
      canvas.drawPath(
        Path()
          ..moveTo(0, 0)
          ..arcTo(disc, start, sweep, false)
          ..close(),
        _glow,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _DiscPainter oldDelegate) =>
      oldDelegate.art != art || oldDelegate.arcs != arcs;
}

Rect _whole(ui.Image image) =>
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());

/// The fixed parts: metal rim, bulb sockets, edge shading, light and axle.
class _FramePainter extends CustomPainter {
  const _FramePainter(this.geo);

  final _Geo geo;

  @override
  void paint(Canvas canvas, Size size) {
    final c = geo.center;
    final outer = geo.outer;
    final disc = geo.disc;
    final discRect = Rect.fromCircle(center: c, radius: disc);
    canvas.drawCircle(
      c,
      disc,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0x00000000), Color(0x00000000), Color(0x99000000)],
          stops: [0, 0.88, 1],
        ).createShader(discRect),
    );
    canvas.drawCircle(
      c,
      disc,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.8, -0.35),
          radius: 0.85,
          colors: [Color(0x2EFFFFFF), Color(0x00FFFFFF)],
        ).createShader(discRect),
    );

    final rim = Path()
      ..fillType = PathFillType.evenOdd
      ..addOval(Rect.fromCircle(center: c, radius: outer))
      ..addOval(discRect);
    canvas.drawPath(
      rim,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _goldLight,
            Color(0xFFE2A932),
            Color(0xFFFFE07A),
            Color(0xFFA8740F),
            Color(0xFFF5C451),
            Color(0xFF7A520A),
          ],
          stops: [0, 0.2, 0.36, 0.58, 0.8, 1],
        ).createShader(
            Rect.fromLTRB(c.dx - outer, c.dy - outer, c.dx, c.dy + outer)),
    );
    canvas.drawPath(
      rim,
      Paint()
        ..shader = SweepGradient(
          colors: [
            for (var i = 0; i < 12; i++)
              i.isEven ? const Color(0x33FFFFFF) : const Color(0x00FFFFFF),
            const Color(0x33FFFFFF),
          ],
        ).createShader(Rect.fromCircle(center: c, radius: outer)),
    );
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..color = _bronze;
    canvas.drawCircle(c, outer - 1.2, edge..strokeWidth = 2.4);
    canvas.drawCircle(c, disc + 1, edge..strokeWidth = 3);
    canvas.drawCircle(
      c,
      outer - 4,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = const Color(0x99FFF4C2),
    );

    final socket = Paint()..color = const Color(0xFF3B2604);
    final unlit = Paint()..color = const Color(0xFF6B4E12);
    for (var i = 0; i < _kBulbs; i++) {
      final at = c + _dir(i * 2 * math.pi / _kBulbs) * geo.ring;
      if (_offscreen(at, size, geo.bulb * 3)) continue;
      canvas.drawCircle(at, geo.bulb * 1.45, socket);
      canvas.drawCircle(at, geo.bulb, unlit);
    }

    final hub = geo.hub;
    canvas.drawCircle(c, hub * 1.1, Paint()..color = const Color(0x99000000));
    canvas.drawCircle(
      c,
      hub,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.3, -0.5),
          colors: [_goldLight, _gold, Color(0xFF8A5E0A)],
          stops: [0, 0.45, 1],
        ).createShader(Rect.fromCircle(center: c, radius: hub)),
    );
    canvas.drawCircle(c, hub * 0.8, Paint()..color = const Color(0xFF1A0F2E));
    canvas.drawCircle(
      c,
      hub * 0.8,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = _goldDeep,
    );
    final star = c + _dir(_kPointerAt) * hub * 0.42;
    final gem = Path();
    for (var i = 0; i < 10; i++) {
      final a = -math.pi / 2 + i * math.pi / 5;
      final r = i.isEven ? hub * 0.26 : hub * 0.11;
      final p = star + Offset(math.cos(a), math.sin(a)) * r;
      i == 0 ? gem.moveTo(p.dx, p.dy) : gem.lineTo(p.dx, p.dy);
    }
    gem.close();
    canvas.drawPath(gem, Paint()..color = _gold);
  }

  @override
  bool shouldRepaint(covariant _FramePainter oldDelegate) =>
      oldDelegate.geo != geo;
}

/// Bulbs and the flapper: the only fixed parts that move.
class _RimPainter extends CustomPainter {
  _RimPainter({required this.motion, required this.art})
      : super(repaint: motion);

  final _Motion motion;
  final _Art art;
  final _bulbs = Paint();
  final _pointer = Paint()..filterQuality = FilterQuality.medium;
  final _transforms = <RSTransform>[];
  final _rects = <Rect>[];
  final _colors = <Color>[];

  double _brightness(int i) {
    final base = switch (motion.mode) {
      _Lights.chase => () {
          final wave =
              0.5 + 0.5 * math.sin(2 * math.pi * (motion.lights - i * 4 / _kBulbs));
          return 0.2 + 0.8 * wave * wave * wave;
        }(),
      _Lights.win => (i + (motion.lights * 2).floor()).isEven ? 1.0 : 0.12,
      _Lights.dim =>
        0.12 + 0.2 * (0.5 + 0.5 * math.sin(2 * math.pi * motion.lights)),
    };
    return motion.beat > 0 ? math.max(base, motion.beat) : base;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final g = art.geo;
    final sprite = art.bulb;
    final src = _whole(sprite);
    final anchor = sprite.width / 2;
    _transforms.clear();
    _rects.clear();
    _colors.clear();
    for (var i = 0; i < _kBulbs; i++) {
      final at = g.center + _dir(i * 2 * math.pi / _kBulbs) * g.ring;
      if (_offscreen(at, size, g.bulb * 3)) continue;
      final b = _brightness(i);
      if (b < 0.03) continue;
      _transforms.add(RSTransform.fromComponents(
        rotation: 0,
        scale: 1 / art.dpr,
        anchorX: anchor,
        anchorY: anchor,
        translateX: at.dx,
        translateY: at.dy,
      ));
      _rects.add(src);
      _colors.add(Color.fromRGBO(255, 255, 255, b.clamp(0.0, 1.0)));
    }
    if (_transforms.isNotEmpty) {
      canvas.drawAtlas(
          sprite, _transforms, _rects, _colors, BlendMode.modulate, null, _bulbs);
    }
    canvas.save();
    canvas.translate(g.pivot.dx, g.pivot.dy);
    canvas.rotate(_kDrawTurn + motion.flap);
    canvas.drawImageRect(art.pointer, _whole(art.pointer), art.pointerRect, _pointer);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RimPainter oldDelegate) =>
      oldDelegate.art != art;
}

/// The hint sweeps down the left side, past the flapper.
const _swipeFrom = _kPointerAt + math.pi * 0.3;
const _swipeSweep = -math.pi * 0.6;

class _SwipeArcPainter extends CustomPainter {
  const _SwipeArcPainter(this.geo);

  final _Geo geo;

  @override
  void paint(Canvas canvas, Size size) {
    final c = geo.center;
    final r = geo.disc * 0.6;
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawArc(
      rect,
      _swipeFrom,
      _swipeSweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round
        ..shader = const SweepGradient(
          startAngle: _swipeFrom + _swipeSweep,
          endAngle: _swipeFrom,
          colors: [Color(0xCCFFFFFF), Color(0x00FFFFFF)],
        ).createShader(rect),
    );
    const end = _swipeFrom + _swipeSweep;
    final tip = c + _dir(end) * r;
    final along = Offset(-math.sin(end), math.cos(end)) * _swipeSweep.sign;
    final across = _dir(end);
    canvas.drawPath(
      Path()
        ..moveTo(tip.dx + along.dx * 16, tip.dy + along.dy * 16)
        ..lineTo(tip.dx + across.dx * 11 - along.dx * 4,
            tip.dy + across.dy * 11 - along.dy * 4)
        ..lineTo(tip.dx - across.dx * 11 - along.dx * 4,
            tip.dy - across.dy * 11 - along.dy * 4)
        ..close(),
      Paint()..color = const Color(0xCCFFFFFF),
    );
  }

  @override
  bool shouldRepaint(covariant _SwipeArcPainter oldDelegate) =>
      oldDelegate.geo != geo;
}

class _SwipeHand extends StatelessWidget {
  const _SwipeHand({required this.geo, required this.animation});

  final _Geo geo;
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = Curves.easeInOutCubic.transform(animation.value);
        final a = _swipeFrom + t * _swipeSweep;
        final at = geo.center + _dir(a) * geo.disc * 0.6;
        final fade = math.sin(animation.value * math.pi);
        return Stack(
          children: [
            Positioned(
              left: at.dx - 24,
              top: at.dy - 8,
              child: Icon(
                Icons.touch_app_rounded,
                size: 60,
                color: Colors.white.withValues(alpha: fade),
                shadows: [
                  Shadow(
                    color: Colors.black.withValues(alpha: 0.6 * fade),
                    blurRadius: 14,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.swipe_rounded, color: _goldLight, size: 30),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            text,
            style: const TextStyle(
              color: Color(0xEEFFFFFF),
              fontSize: 21,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ),
      ],
    );
  }
}

class _Harder extends StatelessWidget {
  const _Harder({super.key, required this.shake});

  final Animation<double> shake;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: shake,
      builder: (context, child) {
        final t = shake.value;
        return Transform.translate(
          offset: Offset(math.sin(t * math.pi * 6) * (1 - t) * 16, 0),
          child: child,
        );
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            context.tr('¡Más fuerte!'),
            style: const TextStyle(
              fontFamily: 'ClimateCrisis',
              fontSize: 30,
              color: _pink,
              shadows: [Shadow(color: Color(0x99FF4D8D), blurRadius: 18)],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            context.tr('Girá más rápido para que cuente'),
            style: const TextStyle(
              color: Color(0xCCFFFFFF),
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// The prize under the flapper while it spins; gold once it is won.
class _Ticker extends StatelessWidget {
  const _Ticker({
    super.key,
    required this.label,
    required this.color,
    this.won = false,
  });

  final String label;
  final Color color;
  final bool won;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0x990D0720),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: won ? _gold : color, width: 2.4),
        boxShadow: won
            ? const [BoxShadow(color: Color(0x66FFD54A), blurRadius: 26)]
            : null,
      ),
      child: Row(
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label.replaceAll('\n', ' ').trim(),
              style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w900,
                height: 1.1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Miss extends StatelessWidget {
  const _Miss({super.key, required this.again, required this.onContinue});

  final bool again;
  final VoidCallback? onContinue;

  @override
  Widget build(BuildContext context) {
    final title = Text(
      context.tr('Seguí participando'),
      style: const TextStyle(
        color: Colors.white,
        fontSize: 30,
        fontWeight: FontWeight.w900,
        letterSpacing: 0.6,
        shadows: [Shadow(color: _pink, blurRadius: 20)],
      ),
    );
    if (onContinue != null) {
      return Row(
        children: [
          Expanded(child: title),
          const SizedBox(width: 12),
          SizedBox(
            height: 56,
            child: FilledButton(
              key: const Key('wheel-continue'),
              onPressed: onContinue,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 56),
                padding: const EdgeInsets.symmetric(horizontal: 22),
              ),
              child: Text(context.tr('Continuar')),
            ),
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        title,
        if (again) ...[
          const SizedBox(height: 8),
          _StatusLine(text: context.tr('Deslizá para girar otra vez')),
        ],
      ],
    );
  }
}

class _PrizeReveal extends StatelessWidget {
  const _PrizeReveal({
    required this.animation,
    required this.name,
    required this.color,
    required this.printing,
    required this.onTap,
  });

  final Animation<double> animation;
  final String name;
  final Color color;
  final bool printing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const Key('prize-reveal'),
      behavior: HitTestBehavior.opaque,
      onTap: printing ? null : onTap,
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          final v = animation.value;
          final pop = Curves.easeOutBack.transform(v);
          final fade = (v / 0.35).clamp(0.0, 1.0);
          return ColoredBox(
            color: Color.fromRGBO(5, 2, 12, 0.74 * fade),
            child: Center(
              child: Opacity(
                opacity: fade,
                child: Transform.scale(scale: 0.6 + 0.4 * pop, child: child),
              ),
            ),
          );
        },
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 24),
          constraints: const BoxConstraints(maxWidth: 440),
          padding: const EdgeInsets.fromLTRB(26, 30, 26, 26),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF2C1B55), Color(0xFF140B2A)],
            ),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: _gold, width: 3),
            boxShadow: const [
              BoxShadow(color: Color(0x59FFD54A), blurRadius: 48, spreadRadius: 2),
              BoxShadow(
                color: Color(0x99000000),
                blurRadius: 30,
                offset: Offset(0, 16),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 92,
                height: 92,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    center: Alignment(-0.3, -0.4),
                    colors: [_goldLight, _gold, Color(0xFFC88A12)],
                  ),
                  boxShadow: [BoxShadow(color: Color(0x88FFD54A), blurRadius: 26)],
                ),
                child: const Icon(Icons.emoji_events_rounded,
                    size: 54, color: _goldInk),
              ),
              const SizedBox(height: 18),
              Text(
                context.tr('¡Ganaste un premio!'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'ClimateCrisis',
                  fontSize: 22,
                  color: _gold,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                name.replaceAll('\n', ' ').trim(),
                textAlign: TextAlign.center,
                maxLines: 3,
                softWrap: true,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 40,
                  height: 1.05,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                width: 64,
                height: 5,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(height: 18),
              if (printing)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.6, color: _gold),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      context.tr('Imprimiendo tu ticket…'),
                      style: const TextStyle(
                        color: _goldLight,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                )
              else
                Text(
                  context.tr('Tocá para continuar'),
                  style: const TextStyle(
                    color: Color(0xB3FFFFFF),
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoPrizes extends StatelessWidget {
  const _NoPrizes();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.background, _night],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.casino_outlined, size: 64, color: AppColors.muted),
            const SizedBox(height: 16),
            Text(
              context.tr('No hay premios'),
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Path _confettiBit(Size size) => Path()
  ..addRRect(RRect.fromRectAndRadius(
    Rect.fromLTWH(0, 0, size.width, size.height * 0.45),
    const Radius.circular(1),
  ));
