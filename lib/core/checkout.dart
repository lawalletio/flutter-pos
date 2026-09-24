import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../domain/config/settings_state.dart';

/// Held across one checkout push. A second tap in the same turn would otherwise
/// stack another payment route, and that route would mint a second invoice.
bool _checkoutPushLock = false;

/// Push [location] once. A repeat tap while this push is being applied, or a
/// tap that would open the route already on screen, is ignored.
void pushCheckout(BuildContext context, String location) {
  if (_checkoutPushLock) return;
  final dest = Uri.parse(location).path;
  // Top route, not the caller's. The screen underneath a payment route still
  // has its own path, and a second tap there must see that payment is open.
  if (GoRouter.of(context).state.uri.path == dest) return;
  _checkoutPushLock = true;
  context.push(location);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _checkoutPushLock = false;
  });
}

/// Routes a checkout to the tip screen first when tips are enabled, otherwise
/// straight to payment — mirroring the webapp's tipEnabled gate. `back` is the
/// route to return to after payment.
void goCheckout(BuildContext context, {required int sats, required String back}) {
  final b = Uri.encodeComponent(back);
  if (appSettings.value.tipEnabled) {
    pushCheckout(context, '/tip?sats=$sats&back=$b');
  } else {
    pushCheckout(context, '/payment?sats=$sats&back=$b');
  }
}
