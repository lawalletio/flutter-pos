import '../../core/ui.dart';
import '../../domain/config/settings_state.dart';
import '../prize/prize_wheel_screen.dart';

/// Prizes typed in the miniapp for the moment. Not saved: a restart plays the
/// coupons from settings again.
// ponytail: in memory on purpose ("del momento"); persist it in
// MerchantTillSettings if merchants want it to survive a restart.
final ruedaCustomPrizes = ValueNotifier<List<PrizeCoupon>>(const []);

/// True plays [ruedaCustomPrizes]; false plays the coupons from settings.
final ruedaUseCustom = ValueNotifier<bool>(false);

bool addRuedaPrize(String text, int chancePercent) =>
    _setRueda(withPrizeAdded(ruedaCustomPrizes.value, text, chancePercent));

bool updateRuedaPrize(String id, String text, int chancePercent) => _setRueda(
    withPrizeUpdated(ruedaCustomPrizes.value, id, text, chancePercent));

void removeRuedaPrize(String id) =>
    _setRueda(ruedaCustomPrizes.value.where((c) => c.id != id).toList());

bool _setRueda(List<PrizeCoupon>? next) {
  if (next == null) return false;
  ruedaCustomPrizes.value = next;
  return true;
}

/// Rueda de la fortuna miniapp: the wheel on its own, with the coupons from
/// settings or a custom set. The navbar's lock keeps players in it.
class RuedaScreen extends StatelessWidget {
  const RuedaScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable:
          Listenable.merge([appSettings, ruedaUseCustom, ruedaCustomPrizes]),
      builder: (context, _) {
        final prizes = ruedaUseCustom.value
            ? ruedaCustomPrizes.value
            : appSettings.value.prizeCoupons;
        // A new prize list is a new wheel; timing changes keep the state.
        return PrizeWheelScreen(
            key: ObjectKey(prizes), coupons: prizes, miniapp: true);
      },
    );
  }
}
