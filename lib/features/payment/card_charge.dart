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
    _sub = NfcChannel.tags().listen((cardUrl) {
      if (!waiting() || collecting || !canTap()) return;
      AppSounds.play(AppSound.card);
      _collect(cardUrl);
    });
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

  /// A card was tapped. The charging screen runs its own timeline; this keeps
  /// pulling the payment and cuts that timeline the moment it settles.
  Future<void> _collect(String cardUrl) async {
    final inv = invoice();
    if (inv == null) return;
    _setCollecting(true);
    try {
      await _lnurl.payWithCard(cardUrl, inv);
      final url = verifyUrl();
      var settled = false;
      if (url != null) {
        for (var i = 0; i < 30 && waiting() && invoice() == inv; i++) {
          if (await _lnurl.checkSettled(url)) {
            settled = true;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 800));
        }
      }
      if (!waiting()) return;
      if (invoice() != inv) {
        _setCollecting(false);
        return;
      }
      if (settled && verifyUrl() == url) {
        collecting = false;
        onPaid();
      } else {
        _setCollecting(false);
        onPending();
      }
    } on LnurlException catch (e) {
      if (!waiting()) return;
      _setCollecting(false);
      onError(e.message);
    } catch (_) {
      if (waiting()) _setCollecting(false);
    }
  }
}
