import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/domain/config/session.dart';
import 'package:lawallet_pos/features/miniapps/miniapps.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ZAPE asks for lud16, lud21 and a printer', () {
    expect(miniapps.single.requires, MiniappRequirement.values.toSet());
  });

  testWidgets('without an address ZAPE is disabled and says why',
      (tester) async {
    merchantAddress.value = '';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('pos/printer'), (_) async => false);
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: MiniappTile(app: miniapps.single))));
    await tester.pumpAndSettle();
    expect(find.text(MiniappRequirement.lud16.message), findsOneWidget);
    expect(find.text(MiniappRequirement.printer.message), findsOneWidget);
    expect(find.text(MiniappRequirement.lud21.message), findsNothing);
    final card = tester.widget<InkWell>(find.descendant(
        of: find.byKey(const Key('miniapp-/zape')),
        matching: find.byType(InkWell)));
    expect(card.onTap, isNull);
  });
}
