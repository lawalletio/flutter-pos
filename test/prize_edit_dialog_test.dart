import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/core/theme.dart';
import 'package:lawallet_pos/domain/config/settings_state.dart';
import 'package:lawallet_pos/features/settings/settings_screen.dart';

void main() {
  tearDown(() {
    appSettings.value = const SettingsState();
  });

  testWidgets('closing the prize editor does not throw', (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    appSettings.value = const SettingsState(
      prizePrintEnabled: true,
      prizeCoupons: [
        PrizeCoupon(id: 'cafe', text: 'Café gratis', chancePercent: 25),
      ],
    );

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: const SettingsSectionScreen(section: SettingsSection.coupons),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Café gratis'));
    await tester.pumpAndSettle();
    expect(find.text('Editar premio'), findsOneWidget);

    await tester.tap(find.text('Cancelar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('Editar premio'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
