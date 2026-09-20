import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/domain/config/settings_persistence.dart';
import 'package:lawallet_pos/domain/config/settings_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('prize settings round-trip via SharedPreferences', () async {
    SharedPreferences.setMockInitialValues({});
    appSettings.value = const SettingsState();
    await settingsPersistence.load();
    expect(appSettings.value.prizePrintEnabled, false);
    expect(appSettings.value.prizeCoupons, isEmpty);

    setPrizePrintEnabled(true);
    setPrizePrintMode(PrizePrintMode.button);
    addPrizeCoupon('Café gratis', 25);

    appSettings.value = const SettingsState();
    await settingsPersistence.load();

    final s = appSettings.value;
    expect(s.prizePrintEnabled, true);
    expect(s.prizePrintMode, PrizePrintMode.button);
    expect(s.prizeCoupons.length, 1);
    expect(s.prizeCoupons.first.text, 'Café gratis');
    expect(s.prizeCoupons.first.chancePercent, 25);
  });
}
