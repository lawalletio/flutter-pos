import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/i18n.dart';
import '../../core/numpad.dart';
import '../../core/print_error.dart';
import '../../core/sounds.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart' show BakedQr;
import '../../data/lnurl/bech32_lnurl.dart';
import '../../data/lnurl/lnurl_service.dart';
import '../../data/nostr/profile_service.dart';
import '../../data/pricing/pricing_service.dart';
import '../../domain/config/currencies.dart';
import '../../domain/config/formatter.dart';
import '../../platform/nfc_channel.dart';
import '../../platform/printer_channel.dart';
import '../payment/card_charge.dart';
import '../payment/invoice_view.dart';
import '../payment/nfc_charging_view.dart';
import 'cards_api.dart';
import 'cards_screen.dart' show formatSats;
import 'cards_widgets.dart';

/// `lightning:` plus the LUD-06 LNURL of [address]'s pay endpoint, or null
/// when it isn't a `user@domain`.
String? lnurlpUri(String address) {
  final at = address.indexOf('@');
  if (at <= 0 || at == address.length - 1) return null;
  final user = address.substring(0, at);
  final domain = address.substring(at + 1);
  final lnurl = encodeLnurl('https://$domain/.well-known/lnurlp/$user');
  return lnurl == null ? null : 'lightning:$lnurl';
}

/// The invoice, card-charge and numpad views come from the till, so they keep
/// the till's theme inside the Cards look.
final _posTheme = buildAppTheme();

/// Loads sats into a card owner's wallet. Two tabs: the owner's LNURL as a QR
/// (any amount, from any wallet), and a numpad that mints an invoice for an
/// exact amount, payable by QR or by tapping another card.
///
/// Whatever lands first counts: the invoice's verify URL, the tapped card
/// settling, or the owner's balance going up. Then the success screen, and
/// a slip with the amount and the new balance prints.
class TopUpView extends StatefulWidget {
  const TopUpView({
    super.key,
    required this.card,
    required this.owner,
    required this.address,
    required this.imageUrl,
    required this.api,
    required this.taps,
    required this.nfcAvailable,
    required this.onDone,
    this.service,
  });

  final CardDetail card;
  final OwnerSummary owner;

  /// The owner's lightning address the sats go to.
  final String address;
  final String imageUrl;
  final CardsApi api;

  /// Card taps from the Cards reader, which owns the native tag stream.
  final Stream<String> taps;
  final bool nfcAvailable;
  final VoidCallback onDone;
  final LnurlService? service;

  @override
  State<TopUpView> createState() => _TopUpViewState();
}

enum _Stage { amount, invoice }

typedef _Receipt = ({int amount, int? before, int? after});

class _TopUpViewState extends State<TopUpView>
    with SingleTickerProviderStateMixin {
  final _pages = PageController();
  late final _enter = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 420));
  late final _enterCurve =
      CurvedAnimation(parent: _enter, curve: Curves.easeOutCubic);
  late final Future<String?> _avatar = nostrProfile.avatarFor(widget.address);
  late final String? _uri = lnurlpUri(widget.address);
  LnurlService get _lnurl => widget.service ?? lnurl;

  var _stage = _Stage.amount;
  var _raw = '0';
  var _sats = 0;
  String? _invoice;
  String? _verifyUrl;
  String? _error;

  /// Bumped per invoice, so a late answer from an abandoned one is dropped.
  var _gen = 0;
  Timer? _verifyPoll;
  Timer? _balancePoll;
  var _polling = false;
  int? _balance;
  var _settled = false;
  _Receipt? _receipt;
  StreamSubscription<String>? _tapSub;

  late final _charge = CardCharge(
    invoice: () => _invoice,
    verifyUrl: () => _verifyUrl,
    waiting: () =>
        mounted && !_settled && _stage == _Stage.invoice && _error == null,
    canTap: () => ModalRoute.of(context)?.isCurrent != false,
    onChange: () {
      if (mounted) setState(() {});
    },
    onPaid: () => _paid(_sats),
    onPending: () =>
        _snack(context.tr('Pago enviado, esperando confirmación…')),
    onError: (message) => _snack(message, error: true),
    service: widget.service,
  );

  @override
  void initState() {
    super.initState();
    _enter.forward();
    pricing.ensureLoaded();
    _balance = widget.owner.balanceSats;
    _charge.available = widget.nfcAvailable;
    _tapSub = widget.taps.listen(_charge.tap);
    // ponytail: polls the owner every 3s while open; switch to the wallet's
    // nostr balance event if the backend ever minds the traffic.
    _balancePoll =
        Timer.periodic(const Duration(seconds: 3), (_) => _checkBalance());
    if (_uri != null) AppSounds.play(AppSound.invoice);
  }

  @override
  void dispose() {
    _stopWatching();
    _tapSub?.cancel();
    _pages.dispose();
    _enter.dispose();
    super.dispose();
  }

  void _stopWatching() {
    _verifyPoll?.cancel();
    _verifyPoll = null;
    _balancePoll?.cancel();
    _balancePoll = null;
    _charge.stop();
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(message, softWrap: true),
        backgroundColor: error ? cardsError : null));
  }

  /// Any rise in the owner's balance is a top-up: the LNURL tab has no
  /// invoice to watch, and an invoice may show up here first.
  Future<void> _checkBalance() async {
    if (_settled || _polling) return;
    _polling = true;
    try {
      final now = (await widget.api.getOwner(widget.card.id))?.balanceSats;
      if (!mounted || _settled || now == null) return;
      final before = _balance;
      if (before != null && now > before) {
        _paid(now - before, after: now);
      } else if (now != before) {
        setState(() => _balance = now);
      }
    } catch (_) {
      // Offline for a beat; the next tick asks again.
    } finally {
      _polling = false;
    }
  }

  Future<void> _paid(int amount, {int? after}) async {
    if (_settled) return;
    _settled = true;
    _stopWatching();
    AppSounds.play(AppSound.paid);
    NfcChannel.vibrate();
    final before = _balance;
    after ??= await _freshBalance();
    // The ledger can trail a settled invoice by a moment: never show less
    // than what was there plus what came in.
    // ponytail: assumes the owner spent nothing mid top-up.
    if (before != null) after = math.max(after ?? 0, before + amount);
    if (!mounted) return;
    setState(() => _receipt = (amount: amount, before: before, after: after));
    final balance = after;
    await printOrAskToContinue(context,
        print: () => PrinterChannel.printCardTopUp(
            amount: formatSats(amount),
            balance: balance == null ? null : formatSats(balance),
            address: widget.address));
  }

  Future<int?> _freshBalance() async {
    try {
      return (await widget.api
              .getOwner(widget.card.id)
              .timeout(const Duration(seconds: 4)))
          ?.balanceSats;
    } catch (_) {
      return null;
    }
  }

  // ── amount → invoice ──────────────────────────────────────────────────────

  void _digit(String d) => setState(() {
        if (_raw == '0') {
          _raw = d == '00' ? '0' : d;
        } else if (_raw.length + d.length <= 9) {
          _raw += d;
        }
      });

  void _backspace() => setState(
      () => _raw = _raw.length <= 1 ? '0' : _raw.substring(0, _raw.length - 1));

  Future<void> _requestInvoice() async {
    final sats = int.tryParse(_raw) ?? 0;
    if (sats <= 0) return;
    final gen = ++_gen;
    setState(() {
      _sats = sats;
      _stage = _Stage.invoice;
      _invoice = null;
      _verifyUrl = null;
      _error = null;
    });
    try {
      final inv = await _lnurl.requestInvoice(widget.address, sats);
      if (!mounted || gen != _gen) return;
      setState(() {
        _invoice = inv.pr;
        _verifyUrl = inv.verify;
      });
      final url = inv.verify;
      if (url != null) {
        _verifyPoll = Timer.periodic(const Duration(seconds: 2), (_) async {
          try {
            if (await _lnurl.checkSettled(url) && gen == _gen) _paid(sats);
          } catch (_) {/* keep polling */}
        });
      }
    } on LnurlException catch (e) {
      if (mounted && gen == _gen) setState(() => _error = e.message);
    } catch (_) {
      if (mounted && gen == _gen) {
        setState(() => _error = 'No se pudo generar la invoice');
      }
    }
  }

  void _backToAmount() {
    _gen++;
    _verifyPoll?.cancel();
    _verifyPoll = null;
    _charge.collecting = false;
    setState(() {
      _stage = _Stage.amount;
      _invoice = null;
      _verifyUrl = null;
      _error = null;
    });
  }

  Future<void> _check() async {
    final url = _verifyUrl;
    if (url == null) return;
    try {
      if (await _lnurl.checkSettled(url)) _paid(_sats);
    } catch (_) {}
  }

  String _satsStr(int sats) => formatToPreference(Currency.sat, sats);
  String _arsStr(int sats) => formatToPreference(
      Currency.ars, pricing.satsToFiat(sats, Currency.ars) ?? 0);

  // ── views ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final receipt = _receipt;
    return FadeTransition(
      opacity: _enterCurve,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.04), end: Offset.zero)
            .animate(_enterCurve),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 450),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: _scaleFade,
          child: receipt == null
              ? _tabs()
              : _TopUpDone(
                  key: const ValueKey('done'),
                  receipt: receipt,
                  address: widget.address,
                  onDone: widget.onDone,
                ),
        ),
      ),
    );
  }

  Widget _tabs() => Column(
        key: const ValueKey('topup'),
        children: [
          _Header(
            imageUrl: widget.imageUrl,
            address: widget.address,
            balance: _balance,
            onBack: widget.onDone,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
            child: _Tabs(controller: _pages),
          ),
          Expanded(
            child: PageView(
              controller: _pages,
              children: [_lnurlPage(), _amountPage()],
            ),
          ),
        ],
      );

  Widget _lnurlPage() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          children: [
            const Spacer(),
            _uri == null
                ? const Icon(Icons.error_outline, color: cardsError, size: 64)
                : _PopIn(
                    child: _LnurlQr(data: _uri, avatar: _avatar),
                  ),
            const Spacer(),
            BrandButton(
              'Amount',
              () => _pages.animateToPage(1,
                  duration: const Duration(milliseconds: 380),
                  curve: Curves.easeOutCubic),
              key: const Key('topup-set-amount'),
              icon: Icons.dialpad,
            ),
            const SizedBox(height: 20),
          ],
        ),
      );

  Widget _amountPage() => AnimatedSwitcher(
        duration: const Duration(milliseconds: 350),
        transitionBuilder: _scaleFade,
        child: _stage == _Stage.amount
            ? _numpad()
            : Theme(
                key: ValueKey('invoice-$_gen'),
                data: _posTheme,
                child: _invoiceStep(),
              ),
      );

  Widget _numpad() {
    final sats = int.tryParse(_raw) ?? 0;
    final ars = pricing.satsToFiat(sats, Currency.ars);
    final t = Theme.of(context).textTheme;
    return Padding(
      key: const ValueKey('numpad'),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // A small bump per key, so each press shows.
                  TweenAnimationBuilder<double>(
                    key: ValueKey(_raw),
                    tween: Tween(begin: 1.06, end: 1),
                    duration: const Duration(milliseconds: 160),
                    builder: (context, s, child) =>
                        Transform.scale(scale: s, child: child),
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(
                            text: _satsStr(sats),
                            style: t.displayMedium?.copyWith(
                                color: sats > 0 ? textPrimary : textSecondary,
                                fontWeight: FontWeight.w800,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ])),
                        TextSpan(
                            text: ' sats',
                            style:
                                t.titleLarge?.copyWith(color: textSecondary)),
                      ]),
                    ),
                  ),
                  if (ars != null && sats > 0)
                    Text('≈ ARS ${_arsStr(sats)}',
                        style: t.titleSmall?.copyWith(color: textSecondary)),
                ],
              ),
            ),
          ),
          Theme(
            data: _posTheme,
            child: Numpad(onDigit: _digit, onBackspace: _backspace),
          ),
          const SizedBox(height: 14),
          BrandButton(
            '${_satsStr(sats)} sats',
            _requestInvoice,
            key: const Key('topup-charge'),
            icon: Icons.bolt,
            enabled: sats > 0,
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _invoiceStep() {
    final error = _error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: cardsError, size: 64),
            const SizedBox(height: 16),
            Text(context.tr(error),
                textAlign: TextAlign.center,
                style: const TextStyle(color: cardsError, fontSize: 18)),
            const SizedBox(height: 28),
            BrandButton('Back', _backToAmount, icon: Icons.arrow_back),
          ],
        ),
      );
    }
    if (_charge.collecting) {
      return NfcChargingView(
        amountLabel: '${_satsStr(_sats)} sats · ≈ ${_arsStr(_sats)} ARS',
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: InvoiceView(
        satsStr: _satsStr(_sats),
        arsStr: _arsStr(_sats),
        invoice: _invoice,
        nfcAvailable: _charge.available,
        tabEnabled: false,
        onCancel: _backToAmount,
        onCopy: () => Clipboard.setData(ClipboardData(text: _invoice ?? '')),
        onCheck: _check,
        onAddTab: () {},
      ),
    );
  }
}

Widget _scaleFade(Widget child, Animation<double> anim) => FadeTransition(
      opacity: anim,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.96, end: 1).animate(anim),
        child: child,
      ),
    );

/// The card, whose wallet this is, and its balance (live while open).
class _Header extends StatelessWidget {
  const _Header({
    required this.imageUrl,
    required this.address,
    required this.balance,
    required this.onBack,
  });

  final String imageUrl;
  final String address;
  final int? balance;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final balance = this.balance;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 20, 8),
      child: Row(
        children: [
          IconButton(
            key: const Key('topup-back'),
            icon: const Icon(Icons.arrow_back, color: textSecondary),
            onPressed: onBack,
          ),
          const SizedBox(width: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.network(imageUrl,
                width: 54,
                height: 34,
                fit: BoxFit.cover,
                cacheWidth: (54 * dpr).round(),
                errorBuilder: (_, __, ___) => Container(
                    width: 54,
                    height: 34,
                    decoration: const BoxDecoration(gradient: tealGradient))),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(address,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.titleSmall?.copyWith(color: textPrimary)),
                const SizedBox(height: 2),
                Row(children: [
                  const _LiveDot(),
                  const SizedBox(width: 8),
                  if (balance != null)
                    _CountUp(
                        from: balance,
                        to: balance,
                        style: t.titleSmall?.copyWith(color: tealBright))
                  else
                    Text('—',
                        style: t.titleSmall?.copyWith(color: textSecondary)),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Two icon tabs on a pill; the highlight follows the page while swiping.
class _Tabs extends StatelessWidget {
  const _Tabs({required this.controller});
  final PageController controller;

  static const _icons = [Icons.qr_code_2, Icons.dialpad];

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: surface1,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: surface2),
      ),
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final page =
              controller.hasClients && controller.position.haveDimensions
                  ? (controller.page ?? 0).clamp(0.0, 1.0)
                  : 0.0;
          return Stack(children: [
            Align(
              alignment: Alignment(-1 + 2 * page, 0),
              child: FractionallySizedBox(
                widthFactor: 0.5,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: tealGradient,
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: [
                      BoxShadow(
                          color: teal.withValues(alpha: 0.45),
                          blurRadius: 14,
                          offset: const Offset(0, 4)),
                    ],
                  ),
                ),
              ),
            ),
            Row(children: [
              for (var i = 0; i < _icons.length; i++)
                Expanded(
                  child: InkWell(
                    key: Key('topup-tab-$i'),
                    borderRadius: BorderRadius.circular(22),
                    onTap: () => controller.animateToPage(i,
                        duration: const Duration(milliseconds: 380),
                        curve: Curves.easeOutCubic),
                    child: Center(
                      child: Icon(_icons[i],
                          size: 26,
                          color: Color.lerp(
                              textSecondary, nearBlack, 1 - (page - i).abs())),
                    ),
                  ),
                ),
            ]),
          ]);
        },
      ),
    );
  }
}

/// The LNURL on a white tile, the owner's avatar in the middle (H error
/// correction leaves room for it).
class _LnurlQr extends StatelessWidget {
  const _LnurlQr({required this.data, required this.avatar});
  final String data;
  final Future<String?> avatar;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final side = math.min(box.maxWidth, 300.0);
      final inner = side - 32;
      return Container(
        width: side,
        height: side,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
                color: teal.withValues(alpha: 0.35),
                blurRadius: 36,
                offset: const Offset(0, 12)),
          ],
        ),
        child: Stack(alignment: Alignment.center, children: [
          BakedQr(
            key: const Key('topup-lnurl'),
            size: inner,
            painter: QrPainter(
              data: data,
              version: QrVersions.auto,
              gapless: true,
              errorCorrectionLevel: QrErrorCorrectLevel.H,
              eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square, color: nearBlack),
              dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.circle, color: nearBlack),
            ),
          ),
          _Avatar(future: avatar, size: inner * 0.24),
        ]),
      );
    });
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.future, required this.size});
  final Future<String?> future;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = DecoratedBox(
      decoration: const BoxDecoration(gradient: tealGradient),
      child: Icon(Icons.bolt, color: nearBlack, size: size * 0.6),
    );
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(4),
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
      ),
      child: ClipOval(
        child: FutureBuilder<String?>(
          future: future,
          builder: (context, snap) {
            final url = snap.data;
            if (url == null) return fallback;
            return Image.network(
              url,
              fit: BoxFit.cover,
              cacheWidth:
                  (size * MediaQuery.devicePixelRatioOf(context)).round(),
              frameBuilder: (context, child, frame, sync) => sync
                  ? child
                  : AnimatedOpacity(
                      opacity: frame == null ? 0 : 1,
                      duration: const Duration(milliseconds: 300),
                      child: child),
              errorBuilder: (_, __, ___) => fallback,
            );
          },
        ),
      ),
    );
  }
}

/// Springs its child in once.
class _PopIn extends StatelessWidget {
  const _PopIn({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.85, end: 1),
        duration: const Duration(milliseconds: 650),
        curve: Curves.elasticOut,
        builder: (context, s, child) => Transform.scale(scale: s, child: child),
        child: child,
      );
}

/// A small teal dot that breathes: the balance is being watched.
class _LiveDot extends StatefulWidget {
  const _LiveDot();

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: FadeTransition(
          opacity: Tween<double>(begin: 0.35, end: 1).animate(_c),
          child: Container(
            width: 8,
            height: 8,
            decoration:
                const BoxDecoration(color: tealBright, shape: BoxShape.circle),
          ),
        ),
      );
}

/// Sats that count from [from] to [to], and on to any new [to].
class _CountUp extends StatelessWidget {
  const _CountUp({
    super.key,
    required this.from,
    required this.to,
    required this.style,
    this.prefix = '',
    this.duration = const Duration(milliseconds: 900),
  });

  final int from;
  final int to;
  final TextStyle? style;
  final String prefix;
  final Duration duration;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: from.toDouble(), end: to.toDouble()),
        duration: duration,
        curve: Curves.easeOutCubic,
        builder: (context, v, _) => Text('$prefix${formatSats(v.round())}',
            style: style
                ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
      );
}

/// Paid: a burst and tick, the amount and the balance counting up, and the
/// slip sliding out like the printer's.
class _TopUpDone extends StatefulWidget {
  const _TopUpDone({
    super.key,
    required this.receipt,
    required this.address,
    required this.onDone,
  });

  final _Receipt receipt;
  final String address;
  final VoidCallback onDone;

  @override
  State<_TopUpDone> createState() => _TopUpDoneState();
}

class _TopUpDoneState extends State<_TopUpDone> with TickerProviderStateMixin {
  late final _burst = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100))
    ..forward();
  late final _slip = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(milliseconds: 450), () {
      if (mounted) _slip.forward();
    });
  }

  @override
  void dispose() {
    _burst.dispose();
    _slip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final r = widget.receipt;
    final after = r.after;
    final slip = CurvedAnimation(parent: _slip, curve: Curves.easeOutCubic);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        children: [
          Image.asset('assets/images/lawallet_logo.png',
              height: 22, cacheHeight: 66),
          const Spacer(),
          SizedBox(
            width: 140,
            height: 140,
            child: RepaintBoundary(
              child: CustomPaint(painter: _BurstPainter(_burst)),
            ),
          ),
          const SizedBox(height: 10),
          _CountUp(
            key: const Key('topup-amount'),
            from: 0,
            to: r.amount,
            prefix: '+',
            style: t.displaySmall
                ?.copyWith(color: tealBright, fontWeight: FontWeight.w800),
          ),
          if (after != null) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.account_balance_wallet_outlined,
                    color: textSecondary, size: 20),
                const SizedBox(width: 8),
                _CountUp(
                  from: r.before ?? after,
                  to: after,
                  duration: const Duration(milliseconds: 1300),
                  style: t.titleMedium?.copyWith(color: textPrimary),
                ),
              ],
            ),
          ],
          const SizedBox(height: 22),
          FadeTransition(
            opacity: slip,
            child: SlideTransition(
              position: Tween(begin: const Offset(0, 0.6), end: Offset.zero)
                  .animate(slip),
              child: FractionallySizedBox(
                widthFactor: 0.82,
                child: TopUpTicket(
                  amount: formatSats(r.amount),
                  balance: after == null ? null : formatSats(after),
                  address: widget.address,
                ),
              ),
            ),
          ),
          const Spacer(),
          BrandButton('OK', widget.onDone,
              key: const Key('topup-done'), icon: Icons.check),
        ],
      ),
    );
  }
}

/// A teal disc that springs in, a tick that draws itself, a ring and sparks
/// flying out. One painter on its own layer, driven by [progress].
class _BurstPainter extends CustomPainter {
  _BurstPainter(this.progress) : super(repaint: progress);
  final Animation<double> progress;

  static double _span(double t, double a, double b) =>
      ((t - a) / (b - a)).clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    final c = size.center(Offset.zero);
    final r = size.shortestSide * 0.32;

    // Ring and sparks, behind the disc.
    final out = Curves.easeOutCubic.transform(_span(t, 0.15, 0.85));
    if (out > 0 && out < 1) {
      canvas.drawCircle(
          c,
          r * (1 + 0.55 * out),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = tealBright.withValues(alpha: 1 - out));
      final spark = Paint()
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = tealBright.withValues(alpha: 1 - out);
      for (var i = 0; i < 10; i++) {
        final a = i * math.pi / 5 + math.pi / 10;
        final d = Offset(math.cos(a), math.sin(a));
        canvas.drawLine(c + d * r * (1.15 + 0.35 * out),
            c + d * r * (1.3 + 0.5 * out), spark);
      }
    }

    final pop = Curves.easeOutBack.transform(_span(t, 0, 0.45));
    if (pop <= 0) return;
    canvas.drawCircle(
        c,
        r * pop,
        Paint()
          ..shader =
              tealGradient.createShader(Rect.fromCircle(center: c, radius: r)));

    final draw = Curves.easeInOut.transform(_span(t, 0.35, 0.75));
    if (draw <= 0) return;
    final tick = Path()
      ..moveTo(c.dx - r * 0.42, c.dy + r * 0.02)
      ..lineTo(c.dx - r * 0.12, c.dy + r * 0.32)
      ..lineTo(c.dx + r * 0.45, c.dy - r * 0.3);
    final metric = tick.computeMetrics().first;
    canvas.drawPath(
        metric.extractPath(0, metric.length * draw),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.16
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = nearBlack);
  }

  @override
  bool shouldRepaint(_BurstPainter old) => old.progress != progress;
}
