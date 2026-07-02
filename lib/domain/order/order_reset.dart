import 'package:flutter/foundation.dart';

import 'current_order.dart';

/// Broadcast signal to clear the current order/cart after a payment completes.
///
/// go_router preserves the menu/paydesk page state across navigation, so simply
/// returning to the menu keeps the old cart. Screens that hold order state listen
/// to this and clear themselves when it fires.
final ValueNotifier<int> orderResetSignal = ValueNotifier<int>(0);

void resetOrder() {
  clearOrderItems();
  orderResetSignal.value++;
}
