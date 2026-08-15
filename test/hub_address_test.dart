import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/domain/config/session.dart';

/// Who the till is selling as. `HubScreen` assigns whatever `/hub` resolves to
/// `merchantAddress`, and `merchantAddress` is what the payment screen turns
/// into an invoice — so getting this wrong charges into the wrong wallet.

void main() {
  tearDown(() => merchantAddress.value = 'barra@lacrypta.ar');

  test('the route wins when it names a merchant', () {
    merchantAddress.value = 'barra@lacrypta.ar';
    expect(hubAddressOr('agustin@lacrypta.ar'), 'agustin@lacrypta.ar');
  });

  test('a bare /hub keeps the merchant already selected', () {
    // The regression: paying or cancelling does `go(back)`, which replaces the
    // whole stack, so the menu's back arrow finds nothing to pop and lands on
    // `/hub` with no address. That used to resolve to a hardcoded
    // barra@lacrypta.ar and silently switch merchants mid-shift.
    merchantAddress.value = 'agustin@lacrypta.ar';
    expect(hubAddressOr(null), 'agustin@lacrypta.ar');
    expect(hubAddressOr(''), 'agustin@lacrypta.ar');
  });

  test('the fallback is never a merchant name', () {
    // Whatever is selected, that is the answer. A literal here is the bug.
    for (final who in ['merch@lacrypta.ar', 'quien@sea.ar']) {
      merchantAddress.value = who;
      expect(hubAddressOr(null), who);
    }
  });
}
