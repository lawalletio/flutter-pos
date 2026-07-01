import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../domain/config/settings_state.dart';

/// Routes a checkout to the tip screen first when tips are enabled, otherwise
/// straight to payment — mirroring the webapp's tipEnabled gate. `back` is the
/// route to return to after payment.
void goCheckout(BuildContext context, {required int sats, required String back}) {
  final b = Uri.encodeComponent(back);
  if (appSettings.value.tipEnabled) {
    context.push('/tip?sats=$sats&back=$b');
  } else {
    context.push('/payment?sats=$sats&back=$b');
  }
}
