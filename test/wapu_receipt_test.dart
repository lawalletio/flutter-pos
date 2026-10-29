import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:lawallet_pos/core/i18n.dart';
import 'package:lawallet_pos/core/theme.dart';
import 'package:lawallet_pos/core/widgets.dart';
import 'package:lawallet_pos/features/wapu/wapu_api.dart';
import 'package:lawallet_pos/features/wapu/wapu_receipt.dart';
import 'package:qr_flutter/qr_flutter.dart';

const _id = '382932db-f7c0-43c3-9ba1-a9f95836421e';

final _createdAt = DateTime.utc(2026, 10, 29, 16, 50, 34);

/// The `yyyy-MM-dd HH:mm:ss` the receipt shows: the device's own clock, not UTC.
final _createdClock =
    DateFormat('yyyy-MM-dd HH:mm:ss').format(_createdAt.toLocal());

const _invoice = 'lnbc10u1p3xyzabcdefghijklmnopqrstuvwxyz0123456789';

/// 689 sats and a 1 sat network fee, bought at a 5% commission (105 USDT cents
/// for 100): 725 sats in all, 36 of them fee. The customer paid $ 1.234,56.
WapuOrder _order({
  String status = 'COMPLETED',
  String payoutAddress = 'cliente@wallet.com',
  DateTime? createdAt,
}) =>
    WapuOrder(
      id: _id,
      status: status,
      payoutStatus: 'completed',
      payoutAddress: payoutAddress,
      amountArsCents: 123456,
      amountOut: 689,
      networkFeeOut: 1,
      watchPending: false,
      createdAt: createdAt,
      totalAmountUsdt: 105,
      fundingAmountUsdt: 100,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// What the last copy button put on the clipboard.
  String? copied;

  setUp(() {
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  final receipt = find.byKey(const Key('wapu-receipt'));
  final copyId = find.byKey(const Key('wapu-copy-id'));
  final idQr = find.byKey(const Key('wapu-id-qr'));
  final qrClose = find.byKey(const Key('wapu-id-qr-close'));

  /// The receipt in a scroll view, as the status view holds it. On a [screen]
  /// (physical size and pixel ratio), with the app's 1.3 text scale
  /// (lib/app.dart): the Z92 is 720x1280 at 1.5, a phone 720x1440 at 2.
  Future<void> show(
    WidgetTester tester,
    WapuOrder order, {
    bool english = false,
    (Size, double)? screen,
  }) async {
    if (screen != null) {
      tester.view
        ..physicalSize = screen.$1
        ..devicePixelRatio = screen.$2;
      addTearDown(tester.view.reset);
    }
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      locale: english ? const Locale('en') : null,
      localizationsDelegates:
          english ? const [AppLocalizationsDelegate()] : null,
      builder: screen != null
          ? (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.3)),
                child: child!,
              )
          : null,
      home: Scaffold(
        body: SingleChildScrollView(
          // The 10 dp of the till's PosBody.
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [WapuReceipt(order: order)],
          ),
        ),
      ),
    ));
    await tester.pump(); // the language loads before the first frame
  }

  group('formatPesos', () {
    test('is the pesos of formatArsCents, with no sign', () {
      expect(formatPesos(123456), '1.234,56');
      expect(formatPesos(1500000), '15.000,00');
      expect(formatPesos(5), '0,05');
    });
  });

  group('shortDestination', () {
    test('leaves an address whole', () {
      expect(shortDestination('cliente@wallet.com'), 'cliente@wallet.com');
      // An address that starts like an invoice is still an address.
      expect(shortDestination('lnurl.cliente.largo@wallet.example.com'),
          'lnurl.cliente.largo@wallet.example.com');
    });

    test('cuts an invoice to its first 12 characters and its last 8', () {
      expect(shortDestination(_invoice), 'lnbc10u1p3xy…23456789');
      expect(shortDestination(_invoice.toUpperCase()), 'LNBC10U1P3XY…23456789');
    });

    test('does not cut what would grow by it', () {
      expect(shortDestination('lnbc10u1p3xyz'), 'lnbc10u1p3xyz');
      expect(shortDestination('ln${'1' * 18}'), 'ln${'1' * 18}', reason: '20');
      expect(shortDestination('ln${'1' * 19}'), 'ln${'1' * 10}…11111111',
          reason: '21');
      expect(shortDestination(''), '');
    });
  });

  group('WapuReceipt', () {
    testWidgets(
        'says each row, the label on the left and the value on the right',
        (tester) async {
      await show(tester, _order(createdAt: _createdAt));

      expect(receipt, findsOneWidget);
      final rows = [
        ('Comprado', '689 SAT'),
        ('Fecha', _createdClock),
        ('Estado', 'Completada'),
        ('Para', 'cliente@wallet.com'),
        ('Comisión de la operación', '36 SAT'),
        ('Depósito del cliente', '1.234,56 ARS'),
        ('Total', '725 SAT'),
      ];
      final card = tester.getRect(receipt);
      for (final (label, value) in rows) {
        expect(find.text(label), findsOneWidget, reason: label);
        expect(find.text(value), findsOneWidget, reason: value);
        final at = tester.getRect(find.text(label));
        final to = tester.getRect(find.text(value));
        // On one line, the label at the left edge and the value at the right.
        expect(at.center.dy, closeTo(to.center.dy, 1), reason: '$label: a row');
        expect(at.left, closeTo(card.left + 16, 0.5), reason: label);
        expect(to.right, closeTo(card.right - 16, 0.5), reason: value);
        expect(at.right, lessThan(to.left), reason: label);
        expect(
            tester.widget<Text>(find.text(label)).style?.color, AppColors.muted,
            reason: label);
      }
      expect(find.text('ID de transacción'), findsOneWidget);
      expect(find.text(_id), findsOneWidget);
      // The id goes under its label, with the fee, the deposit and the total
      // after it, in the order of the merchant's receipt.
      final top = [
        for (final text in [
          'Comprado',
          'Fecha',
          'Estado',
          'Para',
          'ID de transacción',
          _id,
          'Comisión de la operación',
          'Depósito del cliente',
          'Total',
        ])
          tester.getTopLeft(find.text(text)).dy,
      ];
      expect([...top]..sort(), top);
      expect(top.toSet(), hasLength(top.length), reason: 'one under another');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('has an English version of every label and of the state',
        (tester) async {
      await show(tester, _order(createdAt: _createdAt), english: true);

      for (final text in [
        'Purchased',
        'Date',
        'Status',
        'Completed',
        'To',
        'Transaction ID',
        'Transaction fee',
        'Client deposit',
        'Total',
        // The values are not translated.
        '689 SAT',
        _createdClock,
        'cliente@wallet.com',
        _id,
        '36 SAT',
        '1.234,56 ARS',
        '725 SAT',
      ]) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      expect(find.byTooltip('COPY'), findsOneWidget);
      expect(find.byTooltip('SHOW QR'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    for (final (status, amount, state, deposit, english) in [
      (
        'COMPLETED',
        'Comprado',
        'Completada',
        'Depósito del cliente',
        ['Purchased', 'Completed', 'Client deposit'],
      ),
      (
        'SETTLED_TO_BALANCE',
        'Monto',
        'Acreditada en saldo Wapu',
        'Depósito del cliente',
        ['Amount', 'Credited to Wapu balance', 'Client deposit'],
      ),
      for (final expired in ['EXPIRED', 'FUNDING_ISSUED', 'CREATED'])
        (
          expired,
          'Monto',
          'Vencida',
          'Depósito esperado',
          ['Amount', 'Expired', 'Expected deposit'],
        ),
    ]) {
      testWidgets('a $status order is $state, with its own amount and deposit',
          (tester) async {
        await show(tester, _order(status: status));

        expect(find.text(amount), findsOneWidget);
        expect(find.text(state), findsOneWidget);
        expect(find.text(deposit), findsOneWidget);
        expect(find.text('1.234,56 ARS'), findsOneWidget);
        expect(
            find.text(amount == 'Monto' ? 'Comprado' : 'Monto'), findsNothing);

        await show(tester, _order(status: status), english: true);

        for (final line in english) {
          expect(find.text(line), findsOneWidget, reason: line);
        }
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('has no date row when the body of the order has no time',
        (tester) async {
      await show(tester, _order());

      expect(find.text('Fecha'), findsNothing);
      expect(find.text('Comprado'), findsOneWidget);
      expect(find.text('Estado'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('puts the thousands apart with dots', (tester) async {
      await show(
          tester,
          WapuOrder(
            id: _id,
            status: 'COMPLETED',
            payoutStatus: 'completed',
            payoutAddress: 'cliente@wallet.com',
            amountArsCents: 123456789,
            amountOut: 1250000,
            networkFeeOut: 21,
            watchPending: false,
          ));

      expect(find.text('1.250.000 SAT'), findsOneWidget);
      expect(find.text('21 SAT'), findsOneWidget, reason: 'the fee alone');
      expect(find.text('1.250.021 SAT'), findsOneWidget, reason: 'the total');
      expect(find.text('1.234.567,89 ARS'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('shows an invoice cut, and an address whole', (tester) async {
      await show(tester, _order(payoutAddress: _invoice));

      expect(find.text('lnbc10u1p3xy…23456789'), findsOneWidget);
      expect(find.text(_invoice), findsNothing);

      const address = 'una.direccion.muy.larga@un-dominio-largo.example.com';
      await show(tester, _order(payoutAddress: address));

      expect(find.text(address), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('keeps the id as it is, selectable', (tester) async {
      await show(tester, _order());

      expect(
          tester.widget<SelectableText>(find.byType(SelectableText)).data, _id);
      expect(find.text(_id), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    for (final (english, tip, snack) in [
      (false, 'COPIAR', 'ID copiado'),
      (true, 'COPY', 'ID copied'),
    ]) {
      testWidgets(
          'the copy button puts the id on the clipboard and says so'
          '${english ? ', in English' : ''}', (tester) async {
        await show(tester, _order(), english: english);
        expect(find.byTooltip(tip), findsOneWidget);
        expect(tester.widget<IconButton>(copyId).icon,
            isA<Icon>().having((i) => i.icon, 'icon', Icons.copy_rounded));

        await tester.tap(copyId);
        await tester.pump();

        expect(copied, _id, reason: 'the id is never translated');
        expect(find.text(snack), findsOneWidget);
        expect(tester.widget<SnackBar>(find.byType(SnackBar)).duration,
            const Duration(seconds: 1));
        await tester.pumpWidget(const SizedBox());
      });
    }

    for (final (english, tip, close) in [
      (false, 'MOSTRAR QR', 'Cerrar'),
      (true, 'SHOW QR', 'Close'),
    ]) {
      testWidgets(
          'the QR button opens the id as a QR, and Cerrar closes it'
          '${english ? ' (in English)' : ''}', (tester) async {
        await show(tester, _order(), english: english);
        expect(find.byTooltip(tip), findsOneWidget);
        expect(tester.widget<IconButton>(idQr).icon,
            isA<Icon>().having((i) => i.icon, 'icon', Icons.qr_code_2));
        expect(find.byType(AlertDialog), findsNothing);

        await tester.tap(idQr);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        final dialog = find.byType(AlertDialog);
        expect(dialog, findsOneWidget);
        final qr = find.descendant(of: dialog, matching: find.byType(BakedQr));
        expect(qr, findsOneWidget);
        expect(
            tester.widget<BakedQr>(qr).moduleCount,
            QrValidator.validate(data: _id, version: QrVersions.auto)
                .qrCode!
                .moduleCount,
            reason: 'the QR of the id, and of nothing else');
        // On a white card, which is rounded, and the id is under it.
        final card = tester.widget<Container>(
            find.ancestor(of: qr, matching: find.byType(Container)).first);
        final box = card.decoration as BoxDecoration;
        expect(box.color, AppColors.onDark);
        expect(box.borderRadius, isNotNull);
        final idText = find.descendant(of: dialog, matching: find.text(_id));
        expect(idText, findsOneWidget);
        expect(tester.getTopLeft(idText).dy,
            greaterThan(tester.getBottomLeft(qr).dy));
        expect(find.descendant(of: dialog, matching: find.text(close)),
            findsOneWidget);

        await tester.tap(qrClose);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.byType(AlertDialog), findsNothing);
        expect(receipt, findsOneWidget, reason: 'the receipt is where it was');
        await tester.pumpWidget(const SizedBox());
      });
    }

    // The Z92 is 480 dp wide, and the phones the app ships to are as narrow as
    // 360 dp: at the app's 1.3 text scale a label and its value may not fit on
    // one line there, and must not overflow.
    for (final (device, screen, width) in [
      ('the Z92', (const Size(720, 1280), 1.5), 480.0),
      ('a phone', (const Size(720, 1440), 2.0), 360.0),
    ]) {
      for (final english in [false, true]) {
        testWidgets(
            'fits $device without overflowing'
            '${english ? ', in English' : ''}', (tester) async {
          const longAddress =
              'una.direccion.de.un.cliente.con.un.nombre.muy.largo.de.verdad'
              '@un-dominio-de-prueba-bastante-largo.example.com';
          for (final destination in [longAddress, _invoice]) {
            await show(
                tester,
                WapuOrder(
                  id: _id,
                  status: 'SETTLED_TO_BALANCE',
                  payoutStatus: 'settled_to_balance',
                  payoutAddress: destination,
                  amountArsCents: 123456789, // the widest figures it has
                  amountOut: 12500000,
                  networkFeeOut: 21,
                  watchPending: false,
                  createdAt: _createdAt,
                  totalAmountUsdt: 105,
                  fundingAmountUsdt: 100,
                ),
                english: english,
                screen: screen);

            expect(tester.takeException(), isNull, reason: destination);
            final box = tester.getRect(receipt);
            expect(box.left, greaterThanOrEqualTo(0));
            expect(box.right, lessThanOrEqualTo(width), reason: 'the width');
            for (final key in ['wapu-copy-id', 'wapu-id-qr']) {
              expect(tester.getRect(find.byKey(Key(key))).right,
                  lessThanOrEqualTo(box.right),
                  reason: key);
            }
          }

          await tester.tap(idQr);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(tester.takeException(), isNull, reason: 'the QR dialog');
          expect(tester.getRect(find.byType(AlertDialog)).bottom,
              lessThanOrEqualTo(screen.$1.height / screen.$2 + 0.5));
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  });
}
