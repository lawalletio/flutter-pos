import 'dart:async';

import '../../core/sounds.dart';
import '../../data/lnurl/lnurl_service.dart';
import '../../platform/nfc_channel.dart';

/// Tap-to-pay for the invoice on screen, shared by the charge screen and the
/// ZAPE miniapp.
///
/// [arm] turns the card reader on. Each tapped card pays [invoice] through its
/// LNURL-withdraw, then [verifyUrl] is polled until it settles. The screen
/// shows [NfcChargingView] while [collecting] and rebuilds on [onChange].
class CardCharge {
  CardCharge({
    required this.invoice,
    required this.verifyUrl,
    required this.waiting,
    required this.canTap,
    required this.onChange,
    required this.onPaid,
    required this.onPending,
    required this.onError,
    LnurlService? service,
  }) : _lnurl = service ?? lnurl;

  /// The bolt11 a tap pays.
  final String? Function() invoice;

  /// LUD-21 verify URL for [invoice], if the provider has one.
  final String? Function() verifyUrl;

  /// The screen is still waiting for this payment.
  final bool Function() waiting;

  /// A tap may charge right now. Checked on top of [waiting].
  final bool Function() canTap;

  final void Function() onChange;
  final void Function() onPaid;

  /// The card paid but the settlement did not show up in time.
  final void Function() onPending;
  final void Function(String message) onError;

  final LnurlService _lnurl;

  bool available = false;
  bool collecting = false;
  StreamSubscription<String>? _sub;

  /// Arm the card reader while the payment is pending. No button — reader mode
  /// stays active and each tap is delivered via the tag stream.
  Future<void> arm() async {
    if (_sub != null) return;
    available = await NfcChannel.isAvailable();
    if (!available) return;
    onChange();
    await NfcChannel.startSession();
    _sub = NfcChannel.tags().listen(tap);
  }

  /// A card tapped while the invoice waits. [arm] feeds the reader's taps
  /// here; a screen that already holds the reader (Cards) calls it itself,
  /// since a second listener would steal the native tag stream.
  void tap(String cardUrl) {
    if (!waiting() || collecting || !canTap() || invoice() == null) return;
    AppSounds.play(AppSound.card);
    NfcChannel.vibrate();
    _collect(cardUrl);
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    collecting = false;
    NfcChannel.stopSession();
  }

  void _setCollecting(bool value) {
    collecting = value;
    onChange();
  }

  static const _pollEvery = Duration(milliseconds: 500);

  /// Polls once the card server has answered, ~24s, before calling it pending.
  static const _settleTries = 48;

  /// A card was tapped. The charging screen runs its own timeline; this keeps
  /// pulling the payment and cuts that timeline the moment it settles.
  ///
  /// The verify URL is watched from the tap, not after the card server answers:
  /// it pays the invoice before it replies, so the provider usually shows the
  /// settlement first.
  Future<void> _collect(String cardUrl) async {
    final inv = invoice();
    if (inv == null) return;
    _setCollecting(true);
    final url = verifyUrl();
    Object? failure;
    var answered = false;
    final pay = _lnurl.payWithCard(cardUrl, inv).then<void>((_) {},
        onError: (Object e) {
      failure = e;
    }).whenComplete(() => answered = true);
    try {
      var settled = false;
      for (var left = _settleTries;
          url != null &&
              left > 0 &&
              failure == null &&
              waiting() &&
              invoice() == inv;) {
        try {
          if (await _lnurl.checkSettled(url)) {
            settled = true;
            break;
          }
        } catch (_) {/* one failed poll is no answer — keep watching */}
        if (answered) left--;
        await Future<void>.delayed(_pollEvery);
      }
      if (!settled) await pay;
      if (!waiting()) return;
      if (invoice() != inv) {
        _setCollecting(false);
        return;
      }
      if (settled && verifyUrl() == url) {
        collecting = false;
        onPaid();
        return;
      }
      if (failure != null) throw failure!;
      _setCollecting(false);
      onPending();
    } on LnurlException catch (e) {
      if (!waiting()) return;
      _setCollecting(false);
      onError(e.message);
    } catch (_) {
      if (waiting()) _setCollecting(false);
    }
  }
}
