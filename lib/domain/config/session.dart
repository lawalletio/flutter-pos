import 'package:flutter/foundation.dart';

/// The merchant Lightning Address currently signed in. Empty means the till
/// is on the home screen and nobody has entered an address yet.
final ValueNotifier<String> merchantAddress = ValueNotifier<String>('');

/// Leaves the till signed out. Home, the hub, and Settings all use this so
/// they cannot disagree about who is logged in.
void endSession() {
  merchantAddress.value = '';
}

/// Who `/hub` is selling as when the route says nothing.
///
/// **The session, never a merchant name.** `/hub` used to fall back to a
/// hardcoded address, and `HubScreen` assigns whatever it is given to
/// [merchantAddress] — so any navigation that dropped the query parameter
/// silently switched merchants. It happened on an ordinary path: paying (or
/// cancelling) does `go(back)`, which replaces the whole stack, so the menu's
/// back arrow finds nothing to pop and lands on a bare `/hub`.
///
/// That is a money bug, not a cosmetic one: [merchantAddress] is what the
/// payment screen resolves for invoices, so the till would have gone on
/// charging into somebody else's wallet with the operator's own choice still on
/// screen a moment earlier.
///
/// Both writers set the notifier before navigating, so the query parameter is
/// only ever a duplicate of it — and when it is missing, the notifier is right.
String hubAddressOr(String? fromRoute) =>
    fromRoute == null || fromRoute.isEmpty ? merchantAddress.value : fromRoute;
