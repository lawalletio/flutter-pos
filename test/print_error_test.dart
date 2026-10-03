import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/core/print_error.dart';
import 'package:lawallet_pos/core/theme.dart';
import 'package:lawallet_pos/platform/printer_channel.dart';

void main() {
  testWidgets('a print error waits for retry or continue', (tester) async {
    var calls = 0;
    Future<bool>? pending;
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () {
              pending = printOrAskToContinue(context, print: () async {
                calls++;
                if (calls == 1) return const PrintResult(-1403);
                return const PrintResult(0);
              });
            },
            child: const Text('go'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Error de impresión'), findsOneWidget);
    expect(find.text('Sin papel'), findsOneWidget);

    await tester.tap(find.text('Reintentar'));
    await tester.pumpAndSettle();
    expect(await pending, isTrue);
    expect(calls, 2);
    expect(find.text('Error de impresión'), findsNothing);
  });

  testWidgets('continue leaves the failed print behind', (tester) async {
    var calls = 0;
    Future<bool>? pending;
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () {
              pending = printOrAskToContinue(context, print: () async {
                calls++;
                return const PrintResult(-1404);
              });
            },
            child: const Text('go'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Seguir'));
    await tester.pumpAndSettle();
    expect(await pending, isFalse);
    expect(calls, 1);
  });
}
