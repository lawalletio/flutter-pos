import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/core/i18n.dart';
import 'package:lawallet_pos/core/theme.dart';
import 'package:lawallet_pos/features/wapu/wapu_api.dart';
import 'package:lawallet_pos/features/wapu/wapu_error_text.dart';

const _openCopy = 'Hay demasiadas órdenes abiertas. Esperá a que venzan.';
const _historyCopy =
    'No sabemos si la orden se creó. Revisá el Historial antes de reintentar.';
const _tooMany =
    WapuApiException('too many open purchase orders', statusCode: 429);

void main() {
  final detail = find.byKey(const Key('wapu-error-detail'));

  /// Pumps [child] alone on a screen [width] wide.
  Future<void> pumpIn(
    WidgetTester tester,
    Widget child, {
    bool english = false,
    double width = 400,
  }) async {
    await tester.pumpWidget(MaterialApp(
      locale: english ? const Locale('en') : null,
      localizationsDelegates:
          english ? const [AppLocalizationsDelegate()] : null,
      home: Scaffold(
        body: Center(child: SizedBox(width: width, child: child)),
      ),
    ));
    await tester.pump(); // the language loads before the first frame
  }

  Future<void> show(
    WidgetTester tester,
    WapuApiException error, {
    bool creating = false,
    bool english = false,
    double width = 400,
  }) =>
      pumpIn(tester, WapuErrorText(error, creating: creating),
          english: english, width: width);

  testWidgets(
      'a 429 with a backend message shows the mapped copy and the detail',
      (tester) async {
    await show(tester, _tooMany);

    expect(find.text(_openCopy), findsOneWidget);
    expect(tester.widget<Text>(detail).data, 'too many open purchase orders');
  });

  testWidgets('a timeout while creating shows the History copy and no detail',
      (tester) async {
    await show(tester, const WapuApiException('timeout', timeout: true),
        creating: true);

    expect(find.text(_historyCopy), findsOneWidget);
    expect(detail, findsNothing);
  });

  for (final (what, error, copy) in [
    (
      'an empty message',
      const WapuApiException('', statusCode: 500),
      'No se pudo completar la operación'
    ),
    (
      'a blank message',
      const WapuApiException('  ', statusCode: 401),
      'La API key no es válida'
    ),
    (
      'a timeout off a create',
      const WapuApiException('timeout', timeout: true),
      'El servidor no respondió. Probá de nuevo.'
    ),
  ]) {
    testWidgets('$what has no detail line', (tester) async {
      await show(tester, error);

      expect(find.text(copy), findsOneWidget);
      expect(detail, findsNothing);
    });
  }

  testWidgets('a status line is a detail like any other message',
      (tester) async {
    // The API's text for a reply with no `error` field.
    await show(tester, const WapuApiException('HTTP 502', statusCode: 502));

    expect(find.text('No se pudo completar la operación'), findsOneWidget);
    expect(tester.widget<Text>(detail).data, 'HTTP 502');
  });

  testWidgets('the copy is translated and the backend message is not',
      (tester) async {
    await show(tester, _tooMany, english: true);

    expect(
        find.text('There are too many open orders. Wait for them to expire.'),
        findsOneWidget);
    expect(tester.widget<Text>(detail).data, 'too many open purchase orders');
  });

  testWidgets(
      'both lines are plain Material text in the error and muted colors',
      (tester) async {
    await show(tester, _tooMany);

    String drawn(Finder line) => tester
        .widget<RichText>(
            find.descendant(of: line, matching: find.byType(RichText)))
        .text
        .toPlainText();

    // The app's Text would uppercase them, and squeeze each into one line.
    expect(drawn(find.text(_openCopy)), _openCopy);
    expect(drawn(detail), 'too many open purchase orders');
    expect(
        find.descendant(
            of: find.byType(WapuErrorText), matching: find.byType(FittedBox)),
        findsNothing);
    expect(tester.widget<Text>(find.text(_openCopy)).style?.color,
        AppColors.error);
    expect(tester.widget<Text>(detail).style?.color, AppColors.muted);
  });

  testWidgets('a long message wraps within the width', (tester) async {
    await show(
        tester,
        const WapuApiException(
            'The connection errored: Failed host lookup: be.example.invalid',
            statusCode: 599),
        width: 160);

    expect(tester.takeException(), isNull);
    expect(tester.getSize(detail).width, lessThanOrEqualTo(160));
    expect(tester.getSize(detail).height, greaterThan(30)); // several lines
  });

  group('WapuReconnecting', () {
    const copy = 'Problema en la conexión. Intentando reconectar.';
    const lookup = WapuApiException(
        'The connection errored: Failed host lookup: be-prod.wapu.app');
    final reconnecting = find.byKey(const Key('wapu-reconnecting'));

    Future<void> showReconnecting(
      WidgetTester tester,
      WapuApiException error, {
      bool english = false,
    }) =>
        pumpIn(tester, WapuReconnecting(error), english: english);

    testWidgets('says it is reconnecting, muted, with the details closed',
        (tester) async {
      await showReconnecting(tester, lookup);

      expect(find.text(copy), findsOneWidget);
      expect(find.byIcon(Icons.wifi_off), findsOneWidget);
      expect(
          tester.widget<Text>(find.text(copy)).style?.color, AppColors.muted);
      expect(find.text('No se pudo completar la operación'), findsNothing);
      expect(detail, findsNothing);
    });

    testWidgets('a tap opens the details and another closes them',
        (tester) async {
      await showReconnecting(tester, lookup);

      await tester.tap(reconnecting);
      await tester.pump();
      expect(find.text(copy), findsOneWidget);
      expect(find.text('No se pudo completar la operación'), findsOneWidget);
      expect(tester.widget<Text>(detail).data, lookup.message);

      await tester.tap(reconnecting);
      await tester.pump();
      expect(find.text(copy), findsOneWidget);
      expect(find.text('No se pudo completar la operación'), findsNothing);
      expect(detail, findsNothing);
    });

    testWidgets('stays open while a newer failure takes the place of the old',
        (tester) async {
      await showReconnecting(tester, lookup);
      await tester.tap(reconnecting);
      await tester.pump();

      await showReconnecting(tester, const WapuApiException('socket closed'));

      expect(tester.widget<Text>(detail).data, 'socket closed');
    });

    testWidgets('the line is translated', (tester) async {
      await showReconnecting(tester, lookup, english: true);

      expect(find.text('Connection problem. Trying to reconnect.'),
          findsOneWidget);
    });
  });
}
