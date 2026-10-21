import '../../core/amount_pad.dart';
import '../../core/checkout.dart';
import '../../core/i18n.dart';
import '../../core/ui.dart';
import '../../core/widgets.dart';
import '../../domain/order/current_order.dart';
import '../../domain/order/order_reset.dart';

/// Cash register — manual amount entry via numpad + currency selector.
class PaydeskScreen extends StatelessWidget {
  const PaydeskScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PosAppBar(title: context.tr('Modo caja'), lockFlow: '/paydesk'),
      body: PosBody(
        // Reset the entered amount when an order completes.
        child: AmountPad(
          reset: orderResetSignal,
          action: (context, sats) => SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: sats > 0
                  ? () {
                      clearOrderItems(); // manual charge: no line items
                      goCheckout(context, sats: sats, back: '/paydesk');
                    }
                  : null,
              child: Text(context.tr('Cobrar')),
            ),
          ),
        ),
      ),
    );
  }
}
