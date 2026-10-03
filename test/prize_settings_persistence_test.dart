import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/domain/config/session.dart';
import 'package:lawallet_pos/domain/config/settings_persistence.dart';
import 'package:lawallet_pos/domain/config/settings_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    settingsPersistence.debugForgetPrefs();
    merchantAddress.value = '';
    appSettings.value = const SettingsState();
  });

  tearDown(() => merchantAddress.value = '');

  test('till settings round-trip for the signed-in address', () async {
    await settingsPersistence.load();

    merchantAddress.value = 'a@shop.ar';
    setTipEnabled(true);
    setPrizePrintEnabled(true);
    setPrizePrintMode(PrizePrintMode.button);
    addPrizeCoupon('Café gratis', 25);
    await flushPrizeSettings();

    merchantAddress.value = '';
    await flushPrizeSettings();
    await settingsPersistence.load();
    merchantAddress.value = 'a@shop.ar';

    final s = appSettings.value;
    expect(s.tipEnabled, true);
    expect(s.prizePrintEnabled, true);
    expect(s.prizePrintMode, PrizePrintMode.button);
    expect(s.prizeCoupons.length, 1);
    expect(s.prizeCoupons.first.text, 'Café gratis');
    expect(s.prizeCoupons.first.chancePercent, 25);
  });

  test('switching address loads that address or defaults', () async {
    await settingsPersistence.load();

    merchantAddress.value = 'a@shop.ar';
    setTipEnabled(true);
    setWheelOffer(WheelOffer.always);
    addPrizeCoupon('Café', 10);
    await flushPrizeSettings();

    merchantAddress.value = 'b@shop.ar';
    expect(appSettings.value.tipEnabled, false);
    expect(appSettings.value.wheelOffer, WheelOffer.tipOnly);
    expect(appSettings.value.prizeCoupons, isEmpty);

    merchantAddress.value = 'a@shop.ar';
    expect(appSettings.value.tipEnabled, true);
    expect(appSettings.value.wheelOffer, WheelOffer.always);
    expect(appSettings.value.prizeCoupons.single.text, 'Café');
  });

  test('wheel offer round-trips', () async {
    await settingsPersistence.load();
    merchantAddress.value = 'a@shop.ar';
    expect(appSettings.value.wheelOffer, WheelOffer.tipOnly);

    setWheelOffer(WheelOffer.always);
    await flushPrizeSettings();
    merchantAddress.value = '';
    await flushPrizeSettings();
    await settingsPersistence.load();
    merchantAddress.value = 'a@shop.ar';
    expect(appSettings.value.wheelOffer, WheelOffer.always);
  });
}
