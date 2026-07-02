import 'package:flutter/material.dart';

import '../../core/checkout.dart';
import '../../core/i18n.dart';
import '../../core/numpad.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/pricing/pricing_service.dart';
import '../../domain/config/currencies.dart';
import '../../domain/config/formatter.dart';
import '../../domain/order/current_order.dart';
import '../../domain/order/order_reset.dart';

/// Cash register — manual amount entry via numpad + currency selector.
/// Uses a fixed mock BTC rate to show SAT/fiat conversion (engine wires later).
class PaydeskScreen extends StatefulWidget {
  const PaydeskScreen({super.key});
  @override
  State<PaydeskScreen> createState() => _PaydeskScreenState();
}

class _PaydeskScreenState extends State<PaydeskScreen> {
  Currency _currency = Currency.ars;
  String _raw = '0'; // integer string in the selected currency's minor logic

  @override
  void initState() {
    super.initState();
    pricing.ensureLoaded();
    pricing.notifier.addListener(_onRates);
    orderResetSignal.addListener(_onOrderReset);
  }

  @override
  void dispose() {
    pricing.notifier.removeListener(_onRates);
    orderResetSignal.removeListener(_onOrderReset);
    super.dispose();
  }

  void _onRates() {
    if (mounted) setState(() {});
  }

  // Reset the entered amount when an order completes.
  void _onOrderReset() {
    if (mounted) setState(() => _raw = '0');
  }

  num get _enteredAmount {
    final n = num.tryParse(_raw) ?? 0;
    return _currency == Currency.usd ? n / 100 : n;
  }

  int get _sats => pricing.fiatToSats(_enteredAmount, _currency) ?? 0;

  /// Value of the current sats in a given currency's minor-unit raw string.
  String _rawForCurrency(int sats, Currency c) {
    switch (c) {
      case Currency.sat:
        return sats.toString();
      case Currency.ars:
        return (pricing.satsToFiat(sats, Currency.ars) ?? 0).round().toString();
      case Currency.usd:
        return ((pricing.satsToFiat(sats, Currency.usd) ?? 0) * 100)
            .round()
            .toString();
    }
  }

  void _switchCurrency(Currency c) => setState(() {
        // Preserve the entered value by converting it to the new currency
        // (webapp behaviour) instead of resetting to zero.
        final sats = _sats;
        _currency = c;
        _raw = sats == 0 ? '0' : _rawForCurrency(sats, c);
      });

  void _digit(String d) => setState(() {
        if (d == '00' && _raw == '0') return;
        if (_raw == '0') {
          _raw = d == '00' ? '0' : d;
        } else if (_raw.length + d.length <= 12) {
          _raw += d;
        }
      });

  void _back() => setState(() {
        _raw = _raw.length <= 1 ? '0' : _raw.substring(0, _raw.length - 1);
      });

  @override
  Widget build(BuildContext context) {
    final display = formatToPreference(_currency, _enteredAmount);
    final satsStr = formatToPreference(Currency.sat, _sats);
    return Scaffold(
      appBar: PosAppBar(title: context.tr('Modo caja')),
      body: PosBody(
        child: Column(
          children: [
            const SizedBox(height: 12),
            _CurrencySelector(
              value: _currency,
              onChanged: _switchCurrency,
            ),
            const Spacer(),
            Text(
              _currency == Currency.sat ? '$display sats' : '${_currency.code} $display',
              style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              _currency == Currency.sat ? '≈ …' : '≈ $satsStr sats',
              style: const TextStyle(color: AppColors.muted, fontSize: 16),
            ),
            const Spacer(),
            Numpad(onDigit: _digit, onBackspace: _back),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _sats > 0
                    ? () {
                        clearOrderItems(); // manual charge: no line items
                        goCheckout(context, sats: _sats, back: '/paydesk');
                      }
                    : null,
                child: Text(context.tr('Cobrar')),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _CurrencySelector extends StatelessWidget {
  final Currency value;
  final ValueChanged<Currency> onChanged;
  const _CurrencySelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<Currency>(
      style: SegmentedButton.styleFrom(
        backgroundColor: AppColors.surface,
        selectedBackgroundColor: AppColors.primary,
        selectedForegroundColor: Colors.black,
      ),
      segments: currenciesList
          .map((c) => ButtonSegment(value: c, label: Text(c.code)))
          .toList(),
      selected: {value},
      onSelectionChanged: (s) => onChanged(s.first),
      showSelectedIcon: false,
    );
  }
}
