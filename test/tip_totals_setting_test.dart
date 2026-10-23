import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/core/theme.dart';
import 'package:lawallet_pos/domain/config/settings_persistence.dart';
import 'package:lawallet_pos/domain/config/settings_state.dart';
import 'package:lawallet_pos/features/settings/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    settingsPersistence.debugForgetPrefs();
  });
  tearDown(() => appSettings.value = const SettingsState());

  Future<void> pumpGeneral(WidgetTester tester) => tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: const SettingsSectionScreen(section: SettingsSection.general),
        ),
      );

  SwitchListTile toggle(WidgetTester tester) =>
      tester.widget(find.byKey(const Key('tip-show-totals')));

  testWidgets('totals toggle is off-limits while tips are off', (tester) async {
    await pumpGeneral(tester);
    expect(toggle(tester).value, true);
    expect(toggle(tester).onChanged, isNull);
  });

  testWidgets('totals toggle hides the line once tips are on', (tester) async {
    appSettings.value = const SettingsState(tipEnabled: true);
    await pumpGeneral(tester);
    await tester.tap(find.byKey(const Key('tip-show-totals')));
    await tester.pump();
    expect(appSettings.value.tipShowTotals, false);
    expect(toggle(tester).value, false);
  });
}
