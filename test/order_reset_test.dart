import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/domain/order/order_reset.dart';

/// A stand-in for MenuScreen: holds a cart and clears it when [orderResetSignal]
/// fires — the same pattern the real screen uses.
class _MenuStub extends StatefulWidget {
  const _MenuStub();
  @override
  State<_MenuStub> createState() => _MenuStubState();
}

class _MenuStubState extends State<_MenuStub> {
  final List<int> _cart = [];

  @override
  void initState() {
    super.initState();
    orderResetSignal.addListener(_onReset);
  }

  @override
  void dispose() {
    orderResetSignal.removeListener(_onReset);
    super.dispose();
  }

  void _onReset() {
    if (mounted) setState(_cart.clear);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Text('cart:${_cart.length}'),
          TextButton(
            onPressed: () => setState(() => _cart.add(1)),
            child: const Text('add'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const _PaymentStub()),
            ),
            child: const Text('checkout'),
          ),
        ],
      ),
    );
  }
}

/// A stand-in for PaymentScreen: on "finish" it resets the order and pops.
class _PaymentStub extends StatelessWidget {
  const _PaymentStub();
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: TextButton(
        onPressed: () {
          resetOrder();
          Navigator.of(context).pop();
        },
        child: const Text('finish'),
      ),
    );
  }
}

void main() {
  testWidgets('completing a payment clears the cart under the pushed page',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: _MenuStub()));

    await tester.tap(find.text('add'));
    await tester.tap(find.text('add'));
    await tester.pump();
    expect(find.text('cart:2'), findsOneWidget);

    // Push payment (menu stays mounted underneath).
    await tester.tap(find.text('checkout'));
    await tester.pumpAndSettle();

    // Complete payment → resetOrder() + pop back to the menu.
    await tester.tap(find.text('finish'));
    await tester.pumpAndSettle();

    expect(find.text('cart:0'), findsOneWidget);
  });

  test('resetOrder increments and notifies', () {
    var fired = 0;
    void l() => fired++;
    orderResetSignal.addListener(l);
    final before = orderResetSignal.value;
    resetOrder();
    expect(orderResetSignal.value, before + 1);
    expect(fired, 1);
    orderResetSignal.removeListener(l);
  });
}
