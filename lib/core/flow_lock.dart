import 'package:flutter/foundation.dart';

/// Routes each lockable flow may visit, keyed by the route the flow starts on
/// (the one whose navbar shows the lock). The checkout steps are shared by the
/// menu and the cash register.
const lockableFlows = {
  '/cart': {'/cart', '/tip', '/payment', '/ruleta'},
  '/paydesk': {'/paydesk', '/tip', '/payment', '/ruleta'},
  '/zape': {'/zape'},
  '/rueda': {'/rueda'},
  '/cards': {'/cards'},
  '/wapu': {'/wapu', '/wapu/historial', '/wapu/config'},
};

/// The flow the till is locked to, by its starting route, or null when
/// unlocked. Only the navbar's unlock (behind the PIN, when one is set) clears
/// it.
// ponytail: in memory, so a restart comes back unlocked; persist it and
// redirect '/' to it if kiosks get rebooted to escape.
final lockedFlow = ValueNotifier<String?>(null);

/// Router guard: while locked, any route outside the flow goes to its start.
String? lockRedirect(String path) {
  final root = lockedFlow.value;
  if (root == null || lockableFlows[root]!.contains(path)) return null;
  return root;
}
