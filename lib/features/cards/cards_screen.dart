import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/flow_lock.dart';
import '../../core/sounds.dart';
import '../../core/widgets.dart';
import '../../platform/nfc_channel.dart';
import '../../platform/printer_channel.dart';
import 'cards_api.dart';
import 'cards_topup.dart';
import 'cards_widgets.dart';

/// Cards miniapp: the whole LaWallet Card Manager. Sign in with a device-token
/// QR, tap a card, and mint a one-time activation QR (or, for an owner who lost
/// their key, a recovery QR) that prints on the thermal printer.
///
/// Uses plain Material [Text], not the POS uppercase one, to keep
/// card-manager's look. The X leaves; the lock beside it keeps players in.
class CardsScreen extends StatefulWidget {
  const CardsScreen({super.key, this.api});

  final CardsApi? api;

  @override
  State<CardsScreen> createState() => _CardsScreenState();
}

class _CardsScreenState extends State<CardsScreen> {
  final _auth = CardsAuth.instance;
  late final _loading = _auth.load();
  late final _api = widget.api ?? CardsApi();

  /// The X, shown only while unlocked; locked, the lock is the way out.
  void _close() {
    if (lockedFlow.value != null) return;
    context.canPop() ? context.pop() : context.go('/hub');
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: buildCardsTheme(),
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _close();
        },
        child: Scaffold(
          body: GradientBackground(
            child: SafeArea(
              child: FutureBuilder<void>(
                future: _loading,
                builder: (context, snap) =>
                    snap.connectionState != ConnectionState.done
                        ? const SizedBox.shrink()
                        : ValueListenableBuilder<bool>(
                            valueListenable: _auth.loggedIn,
                            builder: (context, loggedIn, _) => loggedIn
                                ? _CardsHome(api: _api, onClose: _close)
                                : _LoginView(onClose: _close),
                          ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "v0.2.7 (14)" from the package info.
class _AppVersion extends StatelessWidget {
  const _AppVersion();

  static final _version = PackageInfo.fromPlatform()
      .then((p) => 'v${p.version} (${p.buildNumber})')
      .catchError((_) => '');

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
        future: _version,
        builder: (context, snap) => Text(snap.data ?? '',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: textSecondary.withValues(alpha: 0.6))),
      );
}

/// The X and the till's lock. Locked, only the lock shows.
class _CloseButton extends StatelessWidget {
  const _CloseButton(this.onClose);
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ValueListenableBuilder<String?>(
            valueListenable: lockedFlow,
            builder: (context, locked, _) => locked != null
                ? const SizedBox.shrink()
                : IconButton(
                    key: const Key('miniapp-close'),
                    icon: const Icon(Icons.close, color: textSecondary),
                    onPressed: onClose,
                  ),
          ),
          const FlowLockButton(flow: '/cards', color: textSecondary),
        ],
      );
}

// ── Login ────────────────────────────────────────────────────────────────────

class _LoginView extends StatefulWidget {
  const _LoginView({required this.onClose});
  final VoidCallback onClose;

  @override
  State<_LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<_LoginView> {
  bool _showManual = false;
  final _manual = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _manual.dispose();
    super.dispose();
  }

  Future<void> _submit(String token) async {
    final reason = await CardsAuth.instance.login(token.trim());
    if (!mounted) return;
    setState(() => _error = switch (reason) {
          null => null, // state flips → the flow shows
          'expired' => 'That token expired — ask for a new one.',
          _ => "That QR isn't a valid device token.",
        });
  }

  Future<void> _scan() async {
    setState(() => _error = null);
    final theme = Theme.of(context);
    final raw = await Navigator.of(context).push<String>(MaterialPageRoute(
        builder: (_) => Theme(
            data: theme,
            child: const TokenScanPage(prompt: 'Scan the device token'))));
    if (raw != null) _submit(raw);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Stack(children: [
      Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FractionallySizedBox(
                widthFactor: 0.72,
                child: AspectRatio(
                  aspectRatio: 1044.89 / 187.5,
                  child: Image.asset('assets/images/lawallet_logo.png',
                      semanticLabel: 'LaWallet'),
                ),
              ),
              const SizedBox(height: 16),
              Text('Card activation',
                  style: t.titleMedium?.copyWith(color: textPrimary)),
              const SizedBox(height: 28),
              Text(
                'Ask your admin for a device token (Settings → Device tokens → Generate) and scan the QR.',
                textAlign: TextAlign.center,
                style: t.bodyMedium?.copyWith(color: textSecondary),
              ),
              const SizedBox(height: 40),
              BrandButton('SCAN TOKEN', _scan,
                  key: const Key('cards-scan-token'),
                  icon: Icons.qr_code_scanner),
              const SizedBox(height: 16),
              if (_showManual) ...[
                TextField(
                  key: const Key('cards-token-field'),
                  controller: _manual,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLines: null,
                  onChanged: (_) => setState(() {}),
                  decoration:
                      const InputDecoration(labelText: 'Device token (JWT)'),
                ),
                const SizedBox(height: 10),
                BrandButton('Use token', () => _submit(_manual.text),
                    key: const Key('cards-use-token'),
                    enabled: _manual.text.trim().isNotEmpty),
              ] else
                GhostButton('Paste token manually',
                    () => setState(() => _showManual = true)),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: cardsError)),
              ],
            ],
          ),
        ),
      ),
      Positioned(top: 4, left: 4, child: _CloseButton(widget.onClose)),
    ]);
  }
}

// ── Home: the tap flow ───────────────────────────────────────────────────────

const _fallbackImage = 'https://veintiuno.lat/images/card-images/card2-40.png';

/// What a minted QR does: drives the screen title, ticket caption and printed
/// subtitle.
enum QrPurpose {
  activate('Print to activate your card', 'Activate your card'),
  recover('Print to recover your account', 'Recover your account');

  const QrPurpose(this.title, this.caption);
  final String title;
  final String caption;
}

/// Owner info for an owned card's detail screen.
sealed class _Owner {
  const _Owner();
}

class _OwnerKnown extends _Owner {
  const _OwnerKnown(this.summary);
  final OwnerSummary summary;
}

/// Older backend without `/owner` (404): no balance, no RECOVER.
class _OwnerUnsupported extends _Owner {
  const _OwnerUnsupported();
}

/// The owner fetch failed: "Balance unavailable", RECOVER disabled.
class _OwnerUnavailable extends _Owner {
  const _OwnerUnavailable();
}

sealed class _Flow {
  const _Flow();
}

class _Scanning extends _Flow {
  const _Scanning();
}

class _LoadingCard extends _Flow {
  const _LoadingCard();
}

/// [owner] is null for unowned cards.
class _Detail extends _Flow {
  const _Detail(this.card, [this.owner]);
  final CardDetail card;
  final _Owner? owner;
}

class _Activating extends _Flow {
  const _Activating();
}

class _Recovering extends _Flow {
  const _Recovering();
}

class _Qr extends _Flow {
  const _Qr(this.card, this.token, this.purpose, {this.autoStart = false});
  final CardDetail card;
  final ActivationToken token;
  final QrPurpose purpose;
  final bool autoStart;
}

/// Loading sats into an owned card's wallet, at its owner's [address].
class _TopUp extends _Flow {
  const _TopUp(this.card, this.owner, this.address);
  final CardDetail card;
  final OwnerSummary owner;
  final String address;
}

class _Failed extends _Flow {
  const _Failed(this.message);
  final String message;
}

class _BlankCard extends _Flow {
  const _BlankCard();
}

String _messageOf(Object e, String fallback) =>
    e is CardsApiException ? e.message : fallback;

class _CardsHome extends StatefulWidget {
  const _CardsHome({required this.api, required this.onClose});
  final CardsApi api;
  final VoidCallback onClose;

  @override
  State<_CardsHome> createState() => _CardsHomeState();
}

class _CardsHomeState extends State<_CardsHome> {
  _Flow _flow = const _Scanning();
  bool _showSettings = false;
  bool _nfcAvailable = false;
  StreamSubscription<String>? _taps;

  /// Taps go here during a top-up: one listener holds the native tag stream.
  final _topUpTaps = StreamController<String>.broadcast();

  CardsApi get _api => widget.api;

  void _set(_Flow flow) {
    if (mounted) setState(() => _flow = flow);
  }

  @override
  void initState() {
    super.initState();
    NfcChannel.isAvailable().then((ok) {
      if (mounted) setState(() => _nfcAvailable = ok);
    });
    NfcChannel.startSession();
    // A LaWallet card's lnurl points at /api/cards/<id>/scan. Anything else
    // (no NDEF, or a non-LaWallet tag) is a blank card.
    _taps = NfcChannel.taps().listen((url) {
      if (_flow is _TopUp) return _topUpTaps.add(url);
      if (_flow is! _Scanning) return;
      // Same cue as a card paying on the charge screen.
      AppSounds.play(AppSound.card);
      NfcChannel.vibrate();
      if (url.contains('/api/cards/')) {
        _handleCard(url);
      } else {
        _set(const _BlankCard());
      }
    });
  }

  @override
  void dispose() {
    _taps?.cancel();
    _topUpTaps.close();
    NfcChannel.stopSession();
    super.dispose();
  }

  /// A tapped card (real NFC) or a manually entered url/id → fetch + show.
  /// Only a real tap carries the SUN proof that RECOVER needs.
  Future<void> _handleCard(String input, {bool manual = false}) async {
    if (_flow is! _Scanning) return;
    _set(const _LoadingCard());
    try {
      final card =
          await _api.getCard(input, sun: manual ? null : parseSun(input));
      if (card.owned) {
        // Owned cards always stop on detail (owner + RECOVER), even with
        // auto-print.
        _set(_Detail(card, await _loadOwner(card.id)));
      } else if (CardsAuth.instance.autoPrint.value) {
        // Auto-print: skip the detail screen, mint + print right away.
        _set(const _Activating());
        _set(_Qr(card, await _api.mintActivation(card.id), QrPurpose.activate,
            autoStart: true));
      } else {
        _set(_Detail(card));
      }
    } catch (e) {
      _set(_Failed(_messageOf(e, "Couldn't read the card.")));
    }
  }

  /// The owner summary, unsupported on an older backend, or unavailable on
  /// failure.
  Future<_Owner> _loadOwner(String cardId) async {
    try {
      final owner = await _api.getOwner(cardId);
      return owner == null ? const _OwnerUnsupported() : _OwnerKnown(owner);
    } catch (_) {
      return const _OwnerUnavailable();
    }
  }

  Future<void> _activate(CardDetail card) async {
    _set(const _Activating());
    try {
      _set(_Qr(card, await _api.mintActivation(card.id), QrPurpose.activate));
    } catch (e) {
      _set(_Failed(_messageOf(e, "Couldn't activate the card.")));
    }
  }

  Future<void> _recover(CardDetail card) async {
    final sun = card.sun;
    if (sun == null) return;
    _set(const _Recovering());
    try {
      _set(_Qr(card, await _api.mintRecovery(card.id, sun), QrPurpose.recover));
    } catch (e) {
      _set(_Failed(_messageOf(e, "Couldn't start the recovery.")));
    }
  }

  void _toScanning() => _set(const _Scanning());

  @override
  Widget build(BuildContext context) {
    if (_showSettings) {
      return _SettingsView(
        onClose: () => setState(() => _showSettings = false),
        onLogout: CardsAuth.instance.logout,
      );
    }
    return switch (_flow) {
      _Scanning() => _ScanningView(
          nfcAvailable: _nfcAvailable,
          onManual: (input) => _handleCard(input, manual: true),
          onOpenSettings: () => setState(() => _showSettings = true),
          onClose: widget.onClose,
        ),
      _LoadingCard() => const _Loading('Getting card details...'),
      _Detail(:final card, :final owner) => _CardDetailView(
          card: card,
          owner: owner,
          onActivate: () => _activate(card),
          onRecover: () => _recover(card),
          onTopUp: (owner, address) => _set(_TopUp(card, owner, address)),
          onCancel: _toScanning,
        ),
      _TopUp(:final card, :final owner, :final address) => TopUpView(
          card: card,
          owner: owner,
          address: address,
          imageUrl: card.imageUrl ?? _fallbackImage,
          api: _api,
          taps: _topUpTaps.stream,
          nfcAvailable: _nfcAvailable,
          onDone: _toScanning,
        ),
      _Activating() => const _Loading('Generating activation QR…'),
      _Recovering() => const _Loading('Generating recovery QR…'),
      _Qr(:final token, :final purpose, :final autoStart) => _QrPrintView(
          key: ObjectKey(token),
          token: token,
          purpose: purpose,
          autoStart: autoStart,
          onDone: _toScanning,
          onCancel: _toScanning,
        ),
      _Failed(:final message) =>
        _FailedView(message: message, onBack: _toScanning),
      _BlankCard() => _BlankCardView(onBack: _toScanning),
    };
  }
}

class _ScanningView extends StatefulWidget {
  const _ScanningView({
    required this.nfcAvailable,
    required this.onManual,
    required this.onOpenSettings,
    required this.onClose,
  });

  final bool nfcAvailable;
  final ValueChanged<String> onManual;
  final VoidCallback onOpenSettings;
  final VoidCallback onClose;

  @override
  State<_ScanningView> createState() => _ScanningViewState();
}

class _ScanningViewState extends State<_ScanningView> {
  bool _showManual = false;
  final _manual = TextEditingController();

  @override
  void dispose() {
    _manual.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final manual = _manual.text;
    return Stack(children: [
      Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Tap your card',
                  style: t.headlineMedium?.copyWith(color: textPrimary)),
              const SizedBox(height: 8),
              Text(widget.nfcAvailable ? 'Scanning NFC…' : 'NFC unavailable',
                  style: t.bodyMedium?.copyWith(color: tealBright)),
              const SizedBox(height: 40),
              const NfcPulse(),
              const SizedBox(height: 40),
              if (_showManual) ...[
                TextField(
                  key: const Key('cards-manual-field'),
                  controller: _manual,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (_) => setState(() {}),
                  decoration:
                      const InputDecoration(labelText: 'Card URL or id'),
                ),
                const SizedBox(height: 10),
                BrandButton('Find card', () {
                  if (manual.trim().isNotEmpty) widget.onManual(manual);
                },
                    key: const Key('cards-find'),
                    enabled: manual.trim().isNotEmpty),
              ] else
                GestureDetector(
                  onTap: () => setState(() => _showManual = true),
                  child: Text('Enter manually',
                      style: t.bodySmall?.copyWith(color: textSecondary)),
                ),
            ],
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          _CloseButton(widget.onClose),
          Expanded(
            child: Text(CardsAuth.instance.host(),
                style: t.labelMedium?.copyWith(color: textSecondary)),
          ),
          Material(
            type: MaterialType.transparency,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(
                  color: tealBright.withValues(alpha: 0.6), width: 1.5),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const Key('cards-settings'),
              onTap: widget.onOpenSettings,
              splashFactory: NoSplash.splashFactory,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Icon(Icons.settings,
                    color: tealBright, size: 24, semanticLabel: 'Settings'),
              ),
            ),
          ),
        ]),
      ),
      const Positioned(left: 0, right: 0, bottom: 16, child: _AppVersion()),
    ]);
  }
}

String formatSats(int sats) =>
    '${NumberFormat('#,##0', 'en_US').format(sats)} ${sats == 1 ? 'sat' : 'sats'}';

class _Loading extends StatelessWidget {
  const _Loading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Center(child: LottieLoader()),
            const SizedBox(height: 8),
            Text(text,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: textSecondary)),
          ],
        ),
      );
}

class _CardDetailView extends StatelessWidget {
  const _CardDetailView({
    required this.card,
    required this.owner,
    required this.onActivate,
    required this.onRecover,
    required this.onTopUp,
    required this.onCancel,
  });

  final CardDetail card;
  final _Owner? owner;
  final VoidCallback onActivate;
  final VoidCallback onRecover;
  final void Function(OwnerSummary owner, String address) onTopUp;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final owner = this.owner;
    // RECOVER shows for owned cards on a backend that has `/owner`; when it
    // can't run, a short reason replaces the action.
    final canOfferRecover = owner != null && owner is! _OwnerUnsupported;
    final known = owner is _OwnerKnown ? owner.summary : null;
    final String? recoverBlocked;
    if (known != null && !known.cardRecoveryEnabled) {
      recoverBlocked = 'The owner turned off card recovery';
    } else if (card.disabled || (known?.cardDisabled ?? false)) {
      recoverBlocked = 'Card is paused by its owner';
    } else if (card.sun == null) {
      recoverBlocked = 'Tap the card to recover';
    } else if (known == null) {
      recoverBlocked = 'Owner info unavailable';
    } else {
      recoverBlocked = null;
    }
    // Top-up needs somewhere to send the sats: the owner's address.
    final topUpTo = known?.primaryAddress ??
        (known == null || known.lightningAddresses.isEmpty
            ? null
            : known.lightningAddresses.first);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 28),
      child: Column(
        children: [
          SizedBox(height: owner != null ? 8 : 24),
          FloatingCard(imageUrl: card.imageUrl ?? _fallbackImage),
          SizedBox(height: owner != null ? 32 : 48),
          // Scrolls only if the owner block outgrows the space above the
          // buttons.
          Expanded(
            child: SingleChildScrollView(
              child: SizedBox(
                width: double.infinity,
                child: Column(
                  children: [
                    Text('Status',
                        style: t.labelMedium?.copyWith(color: textSecondary)),
                    const SizedBox(height: 2),
                    Text(card.status,
                        style: t.titleLarge?.copyWith(color: tealBright)),
                    if (known != null)
                      _OwnerBlock(owner: known)
                    else ...[
                      if (card.lightningAddress != null) ...[
                        const SizedBox(height: 18),
                        Text('Lightning address',
                            style:
                                t.labelMedium?.copyWith(color: textSecondary)),
                        const SizedBox(height: 2),
                        Text('⚡ ${card.lightningAddress}',
                            textAlign: TextAlign.center,
                            style: t.titleMedium?.copyWith(color: textPrimary)),
                      ],
                      if (owner is _OwnerUnavailable) ...[
                        const SizedBox(height: 18),
                        Text('Balance unavailable',
                            style:
                                t.bodyMedium?.copyWith(color: textSecondary)),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: known != null && topUpTo != null
                  ? [
                      if (recoverBlocked != null) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text(recoverBlocked,
                              textAlign: TextAlign.center,
                              style:
                                  t.bodySmall?.copyWith(color: textSecondary)),
                        ),
                        const SizedBox(height: 8),
                      ],
                      BrandButton('Top-up', () => onTopUp(known, topUpTo),
                          key: const Key('cards-topup'), icon: Icons.bolt),
                      const SizedBox(height: 12),
                      Row(children: [
                        Expanded(
                            child: GhostButton('RECOVER', onRecover,
                                key: const Key('cards-recover'),
                                enabled: recoverBlocked == null)),
                        const SizedBox(width: 8),
                        Expanded(child: GhostButton('ACTIVATE', onActivate)),
                        const SizedBox(width: 8),
                        Expanded(child: GhostButton('Cancel', onCancel)),
                      ]),
                    ]
                  : canOfferRecover
                      ? [
                          if (recoverBlocked != null) ...[
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              child: Text(recoverBlocked,
                                  textAlign: TextAlign.center,
                                  style: t.bodySmall
                                      ?.copyWith(color: textSecondary)),
                            ),
                            const SizedBox(height: 8),
                          ],
                          BrandButton('RECOVER', onRecover,
                              key: const Key('cards-recover'),
                              enabled: recoverBlocked == null),
                          const SizedBox(height: 12),
                          Row(children: [
                            Expanded(
                                child: GhostButton('ACTIVATE', onActivate)),
                            const SizedBox(width: 12),
                            Expanded(child: GhostButton('Cancel', onCancel)),
                          ]),
                        ]
                      : [
                          BrandButton('ACTIVATE', onActivate,
                              key: const Key('cards-activate')),
                          const SizedBox(height: 12),
                          GhostButton('Cancel', onCancel),
                        ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The owner's lightning addresses (primary first, from the server) and
/// wallet balance.
class _OwnerBlock extends StatelessWidget {
  const _OwnerBlock({required this.owner});
  final OwnerSummary owner;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final primary = owner.primaryAddress ??
        (owner.lightningAddresses.isEmpty
            ? null
            : owner.lightningAddresses.first);
    // At most 3 addresses on screen: the primary plus 2 others.
    final others = owner.lightningAddresses.where((a) => a != primary).take(2);
    final balance = owner.balanceSats;
    return Column(children: [
      const SizedBox(height: 18),
      Text('Owner', style: t.labelMedium?.copyWith(color: textSecondary)),
      const SizedBox(height: 2),
      Text(primary != null ? '⚡ $primary' : 'No lightning address',
          textAlign: TextAlign.center,
          style: t.titleMedium
              ?.copyWith(color: primary != null ? textPrimary : textSecondary)),
      for (final address in others)
        Text(address,
            textAlign: TextAlign.center,
            style: t.bodySmall?.copyWith(color: textSecondary)),
      const SizedBox(height: 18),
      Text('Balance', style: t.labelMedium?.copyWith(color: textSecondary)),
      const SizedBox(height: 2),
      if (balance != null)
        Text(formatSats(balance),
            style: t.titleLarge?.copyWith(color: tealBright))
      else
        Text('Balance unavailable',
            style: t.bodyMedium?.copyWith(color: textSecondary)),
    ]);
  }
}

class _QrPrintView extends StatefulWidget {
  const _QrPrintView({
    super.key,
    required this.token,
    required this.purpose,
    required this.autoStart,
    required this.onDone,
    required this.onCancel,
  });

  final ActivationToken token;
  final QrPurpose purpose;
  final bool autoStart;
  final VoidCallback onDone;
  final VoidCallback onCancel;

  @override
  State<_QrPrintView> createState() => _QrPrintViewState();
}

class _QrPrintViewState extends State<_QrPrintView>
    with SingleTickerProviderStateMixin {
  // card-manager's slide: 1300 device px up, linear, over 2060 ms, fading out
  // in the last 621 ms.
  late final _anim = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2060));
  late final Future<Uint8List> _png = cardQrPng(widget.token.qrPayload);
  Uint8List? _qr;
  bool _printing = false;

  @override
  void initState() {
    super.initState();
    _png.then((png) {
      if (mounted) setState(() => _qr = png);
    });
    // Warm the printer while the operator reads the ticket; with auto-print,
    // fire right away so the tap alone prints the activation QR.
    PrinterChannel.isAvailable();
    if (widget.autoStart) _startPrint();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  /// Fires the physical print (not awaited: the native print thread finishes
  /// it even if this screen is gone) and runs the slide-up, then back to
  /// scanning.
  Future<void> _startPrint() async {
    if (_printing) return;
    setState(() => _printing = true);
    unawaited(_png.then((png) => PrinterChannel.printCardQr(
        qr: png,
        subtitle: widget.purpose.caption,
        caption: cardDomain(widget.token.qrPayload))));
    await _anim.forward();
    if (mounted) widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Stack(children: [
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(widget.purpose.title,
                    textAlign: TextAlign.center,
                    style: t.titleLarge?.copyWith(color: textPrimary)),
              ),
              const SizedBox(height: 28),
              Padding(
                // Full width minus a 69 device px gutter on each side.
                padding: EdgeInsets.symmetric(horizontal: 69 / dpr),
                child: AnimatedBuilder(
                  animation: _anim,
                  builder: (context, child) {
                    final ms = _anim.value * 2060;
                    final alpha =
                        ms <= 1439 ? 1.0 : (1 - (ms - 1439) / (2060 - 1439));
                    return Transform.translate(
                      offset: Offset(0, -1300 * _anim.value / dpr),
                      child:
                          Opacity(opacity: alpha.clamp(0.0, 1.0), child: child),
                    );
                  },
                  child: PrintTicket(
                    qrContent: widget.token.qrPayload,
                    qrPng: _qr,
                    caption: widget.purpose.caption,
                  ),
                ),
              ),
            ],
          ),
        ),
        Positioned(
          left: 24,
          right: 24,
          bottom: 0,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              BrandButton(_printing ? 'Printing…' : 'PRINT', _startPrint,
                  key: const Key('cards-print'),
                  icon: Icons.print,
                  enabled: !_printing),
              const SizedBox(height: 12),
              GhostButton('Cancel', widget.onCancel, enabled: !_printing),
            ],
          ),
        ),
      ]),
    );
  }
}

class _FailedView extends StatelessWidget {
  const _FailedView({required this.message, required this.onBack});
  final String message;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(message,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: cardsError)),
            const SizedBox(height: 24),
            FractionallySizedBox(
                widthFactor: 0.7, child: BrandButton('Back', onBack)),
          ],
        ),
      );
}

class _BlankCardView extends StatelessWidget {
  const _BlankCardView({required this.onBack});
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.warning, color: cardsError, size: 56),
          const SizedBox(height: 18),
          Text('Blank card',
              style: t.headlineSmall?.copyWith(color: textPrimary)),
          const SizedBox(height: 10),
          Text(
            'This card has no LaWallet data yet. Install it first with the '
            'LaWallet Card Installer app — available on zapstore.',
            textAlign: TextAlign.center,
            style: t.bodyMedium?.copyWith(color: textSecondary),
          ),
          const SizedBox(height: 28),
          FractionallySizedBox(
              widthFactor: 0.7, child: BrandButton('Back', onBack)),
        ],
      ),
    );
  }
}

// ── Settings ─────────────────────────────────────────────────────────────────

/// Session info, JWT expiration, auto-print toggle, log out, version.
class _SettingsView extends StatelessWidget {
  const _SettingsView({required this.onClose, required this.onLogout});
  final VoidCallback onClose;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final auth = CardsAuth.instance;
    final claims = auth.claims;
    final exp = claims?.exp;
    final expText = exp == null
        ? '—'
        : DateFormat('MMM d, yyyy · HH:mm')
            .format(DateTime.fromMillisecondsSinceEpoch(exp * 1000));
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
              child: Text('Settings',
                  style: t.headlineMedium?.copyWith(color: textPrimary)),
            ),
            IconButton(
              icon: const Icon(Icons.close,
                  color: textSecondary, semanticLabel: 'Close'),
              onPressed: onClose,
            ),
          ]),
          const SizedBox(height: 20),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Section('Session', [
                    _Field('Instance', auth.host()),
                    if (claims?.pubkey != null)
                      _Field('Pubkey', _shortenMiddle(claims!.pubkey!)),
                    if (claims != null && claims.scopes.isNotEmpty)
                      _Field('Scopes', claims.scopes.join(', ')),
                    if (claims?.kind != null) _Field('Kind', claims!.kind!),
                    _Field('Token expires', expText),
                  ]),
                  const SizedBox(height: 20),
                  _Section('Preferences', [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Auto-print on tap',
                                  style: t.bodyLarge
                                      ?.copyWith(color: textPrimary)),
                              const SizedBox(height: 2),
                              Text(
                                'Mint and print the activation QR automatically when a card is tapped.',
                                style:
                                    t.bodySmall?.copyWith(color: textSecondary),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        ValueListenableBuilder<bool>(
                          valueListenable: auth.autoPrint,
                          builder: (context, on, _) => Switch(
                            key: const Key('cards-autoprint'),
                            value: on,
                            onChanged: auth.setAutoPrint,
                            thumbColor: WidgetStateProperty.resolveWith((s) =>
                                s.contains(WidgetState.selected)
                                    ? Colors.white
                                    : const Color(0xFF9A9A9A)),
                            trackColor: WidgetStateProperty.resolveWith((s) =>
                                s.contains(WidgetState.selected)
                                    ? tealBright
                                    : const Color(0xFF2A2A2A)),
                            trackOutlineColor: WidgetStateProperty.resolveWith(
                                (s) => s.contains(WidgetState.selected)
                                    ? tealBright
                                    : const Color(0xFF3A3A3A)),
                          ),
                        ),
                      ]),
                    ),
                  ]),
                ],
              ),
            ),
          ),
          GhostButton('Log out', onLogout),
          const SizedBox(height: 16),
          const _AppVersion(),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.children);
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title.toUpperCase(),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: tealBright,
                  fontWeight: FontWeight.w600,
                  fontVariations: const [FontVariation.weight(600)])),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF161616),
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children),
          ),
        ],
      );
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: t.labelMedium?.copyWith(color: textSecondary)),
          const SizedBox(height: 2),
          Text(value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.bodyMedium?.copyWith(color: textPrimary)),
        ],
      ),
    );
  }
}

String _shortenMiddle(String s) =>
    s.length > 24 ? '${s.substring(0, 12)}…${s.substring(s.length - 8)}' : s;
