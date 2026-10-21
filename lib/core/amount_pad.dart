import '../data/pricing/pricing_service.dart';
import '../domain/config/currencies.dart';
import '../domain/config/formatter.dart';
import 'numpad.dart';
import 'theme.dart';
import 'ui.dart';

/// Amount entry of the cash register: currency switcher, the amount with its
/// sats or fiat twin, and the numpad. [action] is the button underneath,
/// given the amount in sats.
class AmountPad extends StatefulWidget {
  const AmountPad({super.key, required this.action, this.reset});

  final Widget Function(BuildContext context, int sats) action;

  /// Clears the amount each time it fires.
  final Listenable? reset;

  @override
  State<AmountPad> createState() => _AmountPadState();
}

class _AmountPadState extends State<AmountPad> {
  Currency _currency = Currency.ars;
  String _raw = '0'; // integer string in the selected currency's minor logic

  @override
  void initState() {
    super.initState();
    pricing.ensureLoaded();
    pricing.notifier.addListener(_onRates);
    widget.reset?.addListener(_onReset);
  }

  @override
  void dispose() {
    pricing.notifier.removeListener(_onRates);
    widget.reset?.removeListener(_onReset);
    super.dispose();
  }

  void _onRates() {
    if (mounted) setState(() {});
  }

  void _onReset() {
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
    return Column(
      children: [
        const SizedBox(height: 12),
        CurrencySelector(value: _currency, onChanged: _switchCurrency),
        // The amount takes what the numpad leaves and shrinks on short
        // screens rather than pushing the button off.
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  _currency == Currency.sat
                      ? '$display sats'
                      : '${_currency.code} $display',
                  style: const TextStyle(
                      fontSize: 44, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(height: 6),
              Flexible(
                child: Text(
                  _currency == Currency.sat ? '≈ …' : '≈ $satsStr sats',
                  style: const TextStyle(color: AppColors.muted, fontSize: 16),
                ),
              ),
            ],
          ),
        ),
        Numpad(onDigit: _digit, onBackspace: _back),
        const SizedBox(height: 16),
        widget.action(context, _sats),
        const SizedBox(height: 12),
      ],
    );
  }
}

class CurrencySelector extends StatelessWidget {
  final Currency value;
  final ValueChanged<Currency> onChanged;
  const CurrencySelector(
      {super.key, required this.value, required this.onChanged});

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
