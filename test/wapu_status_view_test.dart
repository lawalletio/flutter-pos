import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:lawallet_pos/core/i18n.dart';
import 'package:lawallet_pos/core/theme.dart';
import 'package:lawallet_pos/features/wapu/wapu_api.dart';
import 'package:lawallet_pos/features/wapu/wapu_status_view.dart';

/// The clock every view is read at, so the countdown is the same on any day.
final _now = DateTime.utc(2026, 10, 29, 15, 0);

const _alias = 'Mi.Alias.Cobro';
const _cvu = '0000003100012345678901';
const _id = 'tent_9f2c1a7b';
const _hash =
    '3f9a1c0be2d84a76b5c3d1e0f9a8b7c6d5e4f30211223344556677889900aabb';

final _lateWatchUntil = DateTime.utc(2026, 10, 29, 15, 41);

/// The `HH:mm` the late-watch copy shows: the device's own clock, not UTC.
final _lateWatchClock = DateFormat.Hm().format(_lateWatchUntil.toLocal());

/// An order as the backend reports it. Only the orders that have bank details
/// carry [alias] and [cvu]: EXECUTED and COMPLETED ones come back without.
WapuOrder _order({
  String status = 'FUNDING_ISSUED',
  String payoutStatus = 'waiting_ars',
  String payoutAddress = 'cliente@wallet.com',
  int amountOut = 12500,
  bool watchPending = true,
  DateTime? createdAt,
  DateTime? expiresAt,
  DateTime? lateWatchUntil,
  int? totalAmountUsdt,
  int? fundingAmountUsdt,
  String? alias,
  String? cvu,
  String? paymentHash,
  String? errorCode,
}) =>
    WapuOrder(
      id: _id,
      status: status,
      payoutStatus: payoutStatus,
      payoutAddress: payoutAddress,
      amountArsCents: 1500037,
      amountOut: amountOut,
      networkFeeOut: 21,
      watchPending: watchPending,
      createdAt: createdAt,
      expiresAt: expiresAt,
      lateWatchUntil: lateWatchUntil,
      totalAmountUsdt: totalAmountUsdt,
      fundingAmountUsdt: fundingAmountUsdt,
      alias: alias,
      cvu: cvu,
      paymentHash: paymentHash,
      errorCode: errorCode,
    );

/// 14:59 left of the payment window.
final _waiting = _order(
  alias: _alias,
  cvu: _cvu,
  expiresAt: _now.add(const Duration(seconds: 899)),
);

final _created = _order(
  status: 'CREATED',
  watchPending: false,
  expiresAt: _now.add(const Duration(minutes: 5)),
);

/// Its window closed a second ago and the poll has not said so yet.
final _createdPastExpiry = _order(
  status: 'CREATED',
  watchPending: false,
  expiresAt: _now.subtract(const Duration(seconds: 1)),
);

/// Closed, but a late transfer is still detected (the backend still sends the
/// bank details then).
final _lateWatch = _order(
  status: 'EXPIRED',
  payoutStatus: 'expired',
  alias: _alias,
  cvu: _cvu,
  lateWatchUntil: _lateWatchUntil,
);

final _expired = _order(
  status: 'EXPIRED',
  payoutStatus: 'expired',
  watchPending: false,
);

/// Its window closed 3 s ago and the poll has not said so yet: the backend
/// still calls it FUNDING_ISSUED, and still watches it.
final _waitingPastExpiry = _order(
  alias: _alias,
  cvu: _cvu,
  expiresAt: _now.subtract(const Duration(seconds: 3)),
  lateWatchUntil: _lateWatchUntil,
);

/// What the view says of an order that expired, in Spanish.
const _noArs = 'No se recibieron ARS ni se enviaron sats.';

final _sending = _order(status: 'EXECUTED', payoutStatus: 'sending');
final _review = _order(status: 'EXECUTED', payoutStatus: 'review');

final _completed = _order(
  status: 'COMPLETED',
  payoutStatus: 'completed',
  watchPending: false,
  paymentHash: _hash,
);

final _settled = _order(
  status: 'SETTLED_TO_BALANCE',
  payoutStatus: 'settled_to_balance',
  watchPending: false,
);

/// Credited to the balance because the customer's invoice expired first.
final _settledInvoiceExpired = _order(
  status: 'SETTLED_TO_BALANCE',
  payoutStatus: 'settled_to_balance',
  watchPending: false,
  errorCode: 'invoice_expired',
);

/// What the view says of an order whose invoice expired, in Spanish: the
/// message up to the account, which is its username when that is known.
const _invoiceExpired = 'La orden expiró pero se detectó el depósito en ARS, '
    'el saldo fue acreditado en';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// What the last Copiar put on the clipboard.
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

  final newSaleBig = find.byKey(const Key('wapu-new-sale-big'));
  final receipt = find.byKey(const Key('wapu-receipt'));
  final fund = find.byKey(const Key('wapu-fund'));
  final logo = find.byKey(const Key('wapu-logo'));

  Future<void> show(
    WidgetTester tester,
    WapuOrder order, {
    VoidCallback? onRequestFunding,
    VoidCallback? onNewSale,
    bool busy = false,
    bool english = false,
    String? wapuUser,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      locale: english ? const Locale('en') : null,
      localizationsDelegates:
          english ? const [AppLocalizationsDelegate()] : null,
      home: Scaffold(
        body: WapuStatusView(
          order: order,
          now: _now,
          onRequestFunding: onRequestFunding,
          onNewSale: onNewSale,
          busy: busy,
          wapuUser: wapuUser,
        ),
      ),
    ));
    await tester.pump(); // the language loads before the first frame
  }

  /// What a widget really draws, as a string.
  String drawn(WidgetTester tester, Finder of) => tester
      .widget<RichText>(
          find.descendant(of: of, matching: find.byType(RichText)))
      .text
      .toPlainText();

  group('formatArsCents', () {
    test('groups the pesos with dots and puts the cents after a comma', () {
      expect(formatArsCents(1500037), r'$ 15.000,37');
      expect(formatArsCents(5), r'$ 0,05');
    });

    test('always has two decimals', () {
      expect(formatArsCents(1500000), r'$ 15.000,00');
      expect(formatArsCents(0), r'$ 0,00');
      expect(formatArsCents(120), r'$ 1,20');
    });
  });

  group('formatCountdown', () {
    test('is minutes and seconds, two digits each', () {
      expect(formatCountdown(const Duration(seconds: 899)), '14:59');
      expect(formatCountdown(const Duration(minutes: 5)), '05:00');
      expect(formatCountdown(const Duration(seconds: 65)), '01:05');
    });

    test('stops at zero', () {
      expect(formatCountdown(Duration.zero), '00:00');
      expect(formatCountdown(const Duration(seconds: -3)), '00:00');
    });
  });

  group('FUNDING_ISSUED', () {
    testWidgets('shows the alias, the exact amount and the countdown',
        (tester) async {
      await show(tester, _waiting);

      expect(find.text('Esperando la transferencia'), findsOneWidget);
      expect(find.text('Alias'), findsOneWidget);
      expect(find.text(_alias), findsOneWidget);
      expect(find.text('CVU'), findsNothing);
      expect(find.text(_cvu), findsNothing, reason: 'the alias only');
      expect(find.text('Monto exacto'), findsOneWidget);
      expect(find.text(r'$ 15.000,37'), findsOneWidget);
      expect(find.text('Transferí exactamente este monto, con centavos'),
          findsOneWidget);
      expect(find.text('Vence en 14:59'), findsOneWidget);
      expect(find.text('Copiar'), findsNWidgets(2));
      expect(newSaleBig, findsNothing, reason: 'the order is still open');
      await tester.pumpWidget(const SizedBox());
    });

    for (final (what, key, text) in [
      ('the alias', 'wapu-copy-alias', _alias),
      ('the amount, as a plain decimal', 'wapu-copy-amount', '15000.37'),
    ]) {
      testWidgets('copying $what puts $text on the clipboard and says so',
          (tester) async {
        await show(tester, _waiting);

        await tester.tap(find.byKey(Key(key)));
        await tester.pump();

        expect(copied, text);
        expect(find.text('Copiado'), findsOneWidget);
        expect(tester.widget<SnackBar>(find.byType(SnackBar)).duration,
            const Duration(seconds: 1));
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('keeps the value as typed: no uppercase, no squeezing',
        (tester) async {
      await show(tester, _waiting);

      // The app's Text would uppercase these, and wrap each in a FittedBox.
      for (final value in [_alias, r'$ 15.000,37']) {
        expect(drawn(tester, find.text(value)), value);
        expect(
            find.descendant(
                of: find.text(value), matching: find.byType(FittedBox)),
            findsNothing,
            reason: value);
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('leaves out a bank row that has no value', (tester) async {
      await show(tester, _order(cvu: _cvu));

      expect(find.text('Alias'), findsNothing);
      expect(find.text('Monto exacto'), findsOneWidget);
      expect(find.text('Copiar'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('counts down to the last second, and then it has expired',
        (tester) async {
      await show(
          tester,
          _order(
              alias: _alias,
              cvu: _cvu,
              expiresAt: _now.add(const Duration(seconds: 1))));

      expect(find.text('Vence en 00:01'), findsOneWidget);
      expect(find.text(_alias), findsOneWidget);
      expect(receipt, findsNothing);

      // At the expiry there is no 00:00 to show: the order is over.
      await show(tester, _order(alias: _alias, cvu: _cvu, expiresAt: _now));

      expect(find.textContaining('Vence en'), findsNothing);
      expect(find.text('Esperando la transferencia'), findsNothing);
      expect(find.text('Orden vencida'), findsOneWidget);
      expect(receipt, findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('past its expiry shows the details, not a stuck countdown',
        (tester) async {
      await show(tester, _waitingPastExpiry);

      expect(find.text('Orden vencida'), findsOneWidget);
      expect(find.text(_noArs), findsOneWidget);
      expect(
          find.text('Si el cliente ya transfirió, '
              'lo seguimos buscando hasta las $_lateWatchClock'),
          findsOneWidget);
      expect(find.textContaining('Vence en'), findsNothing);
      for (final gone in [
        'Esperando la transferencia',
        'Alias',
        'Monto exacto',
        'Copiar',
        _alias,
      ]) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
      // The receipt of an order that expired: nothing was deposited.
      expect(receipt, findsOneWidget);
      expect(find.text('Estado'), findsOneWidget);
      expect(find.text('Vencida'), findsOneWidget);
      expect(find.text('Depósito esperado'), findsOneWidget);
      expect(find.text('15.000,37 ARS'), findsOneWidget);
      expect(newSaleBig, findsNothing, reason: 'still being watched');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('past its expiry and no longer watched offers Nueva venta',
        (tester) async {
      await show(
          tester,
          _order(
              alias: _alias,
              cvu: _cvu,
              watchPending: false,
              expiresAt: _now.subtract(const Duration(seconds: 3))));

      expect(find.text('Orden vencida'), findsOneWidget);
      expect(find.textContaining('lo seguimos buscando'), findsNothing);
      expect(newSaleBig, findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('has no countdown without an expiry', (tester) async {
      await show(tester, _order(alias: _alias, cvu: _cvu));

      expect(find.textContaining('Vence en'), findsNothing);
      expect(find.text(_alias), findsOneWidget);
      expect(find.text('Orden vencida'), findsNothing,
          reason: 'with no expiry the window never closes');
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('CREATED', () {
    testWidgets('offers to ask for the transfer details', (tester) async {
      var asked = 0;
      await show(tester, _created, onRequestFunding: () => asked++);

      expect(find.text('Orden creada'), findsOneWidget);
      expect(find.text('Pedir datos de transferencia'), findsOneWidget);
      expect(find.text('Copiar'), findsNothing, reason: 'no bank details yet');
      expect(newSaleBig, findsNothing);

      await tester.tap(fund);
      expect(asked, 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('waits while the details are being asked for', (tester) async {
      var asked = 0;
      await show(tester, _created, onRequestFunding: () => asked++, busy: true);

      expect(tester.widget<FilledButton>(fund).onPressed, isNull);
      expect(
          find.descendant(
              of: fund, matching: find.byType(CircularProgressIndicator)),
          findsOneWidget);
      await tester.tap(fund, warnIfMissed: false);
      expect(asked, 0);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('past its expiry it is an expired order', (tester) async {
      await show(tester, _createdPastExpiry);

      expect(find.text('Orden vencida'), findsOneWidget);
      expect(find.text(_noArs), findsOneWidget);
      expect(fund, findsNothing);
      expect(find.text('Orden creada'), findsNothing);
      expect(receipt, findsOneWidget);
      expect(find.text('Vencida'), findsOneWidget);
      expect(newSaleBig, findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('EXPIRED', () {
    testWidgets('with the late watch on, says until when a transfer is seen',
        (tester) async {
      await show(tester, _lateWatch);

      expect(find.text('Orden vencida'), findsOneWidget);
      expect(find.text(_noArs), findsOneWidget);
      expect(
          find.text('Si el cliente ya transfirió, '
              'lo seguimos buscando hasta las $_lateWatchClock'),
          findsOneWidget);
      expect(find.text('Alias'), findsNothing,
          reason: 'there is no transfer to ask for any more');
      expect(receipt, findsOneWidget);
      expect(newSaleBig, findsNothing, reason: 'still being watched');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('with the late watch on but no time, says only that it passed',
        (tester) async {
      await show(tester, _order(status: 'EXPIRED', payoutStatus: 'expired'));

      expect(find.text('Orden vencida'), findsOneWidget);
      expect(find.text(_noArs), findsOneWidget);
      expect(find.textContaining('lo seguimos buscando'), findsNothing);
      expect(receipt, findsOneWidget);
      expect(newSaleBig, findsNothing, reason: 'still being watched');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
        'closed, shows the receipt, says no ARS came, offers Nueva venta',
        (tester) async {
      await show(tester, _expired);

      expect(find.text('Orden vencida'), findsOneWidget);
      expect(find.text(_noArs), findsOneWidget);
      expect(find.textContaining('lo seguimos buscando'), findsNothing);
      expect(receipt, findsOneWidget);
      expect(find.text('Vencida'), findsOneWidget);
      expect(find.text('Depósito esperado'), findsOneWidget);
      expect(find.text('Depósito del cliente'), findsNothing);
      expect(find.text('Monto'), findsOneWidget);
      expect(find.text('12.521 SAT'), findsOneWidget);
      expect(find.text(_id), findsOneWidget);
      expect(newSaleBig, findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('EXECUTED', () {
    testWidgets('while sending, says the sats are on their way and to whom',
        (tester) async {
      await show(tester, _sending);

      expect(find.text('Pago recibido'), findsOneWidget);
      expect(find.text('Enviando los sats…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('12.500 sats → cliente@wallet.com'), findsOneWidget);
      expect(newSaleBig, findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('shows the Wapu logo while sending, and not in review',
        (tester) async {
      await show(tester, _sending);
      expect(logo, findsOneWidget);
      expect(find.text('Pago recibido'), findsOneWidget);

      await show(tester, _review);
      expect(logo, findsNothing);
      expect(find.text('Pago recibido'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('puts the logo on a white plate, so its outline shows',
        (tester) async {
      await show(tester, _sending);

      final plate = tester.widget<Container>(
          find.ancestor(of: logo, matching: find.byType(Container)).first);
      expect((plate.decoration as BoxDecoration).color, AppColors.onDark);
      expect(tester.getSize(logo), const Size(140, 140));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('leaves out the amount line when the order carries none',
        (tester) async {
      for (final order in [
        _order(status: 'EXECUTED', payoutStatus: 'sending', amountOut: 0),
        _order(status: 'EXECUTED', payoutStatus: 'sending', payoutAddress: ''),
      ]) {
        await show(tester, order);

        expect(find.text('Pago recibido'), findsOneWidget);
        expect(find.textContaining('sats →'), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('in review, says to keep the order id', (tester) async {
      await show(tester, _review);

      expect(find.text('En revisión'), findsOneWidget);
      expect(find.text('Guardá el ID de la orden: $_id'), findsOneWidget);
      expect(newSaleBig, findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('lets the operator select the order id, as it is',
        (tester) async {
      await show(tester, _review);

      // Selectable text is not the app's Text: nothing uppercases the id.
      expect(tester.widget<SelectableText>(find.byType(SelectableText)).data,
          'Guardá el ID de la orden: $_id');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('with any other payout status says the sats are on their way',
        (tester) async {
      // The ARS was received, whatever the payout says: never the raw status.
      for (final payout in ['pending', 'failed', '']) {
        await show(tester, _order(status: 'EXECUTED', payoutStatus: payout));

        expect(find.text('Pago recibido'), findsOneWidget, reason: payout);
        expect(find.text('Enviando los sats…'), findsOneWidget, reason: payout);
        expect(find.text('EXECUTED'), findsNothing, reason: payout);
        expect(find.text('En revisión'), findsNothing, reason: payout);
        expect(newSaleBig, findsNothing, reason: payout);
      }
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('COMPLETED', () {
    testWidgets('says what the customer received, then shows the receipt',
        (tester) async {
      await show(tester, _completed);

      final headline = find.text('¡Listo! El cliente recibió 12.500 sats');
      expect(headline, findsOneWidget);
      expect(receipt, findsOneWidget);
      // The receipt is of this order: its id and its purchased sats, fee and
      // total, the total being the sats of the headline.
      expect(find.text(_id), findsOneWidget);
      expect(find.text('12.521 SAT'), findsOneWidget);
      expect(find.text('21 SAT'), findsOneWidget);
      expect(find.text('12.500 SAT'), findsOneWidget);
      expect(find.text('15.000,37 ARS'), findsOneWidget);
      expect(find.text('Completada'), findsOneWidget);
      expect(tester.getTopLeft(headline).dy,
          lessThan(tester.getTopLeft(receipt).dy));
      expect(tester.getTopLeft(receipt).dy,
          lessThan(tester.getTopLeft(newSaleBig).dy));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no longer shows the payment hash on its own', (tester) async {
      await show(tester, _completed);

      expect(find.text(_hash), findsNothing);
      expect(find.byType(SelectableText), findsOneWidget,
          reason: 'only the id in the receipt');
      expect(
          tester.widget<SelectableText>(find.byType(SelectableText)).data, _id);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('shows the receipt without a date when the body has none',
        (tester) async {
      await show(tester, _order(status: 'COMPLETED', watchPending: false));

      expect(find.textContaining('¡Listo!'), findsOneWidget);
      expect(receipt, findsOneWidget);
      expect(find.text('Fecha'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('shows the date of the order in the device time',
        (tester) async {
      final created = DateTime.utc(2026, 10, 29, 16, 50, 34);
      await show(
          tester,
          _order(
              status: 'COMPLETED',
              watchPending: false,
              createdAt: created,
              totalAmountUsdt: 105,
              fundingAmountUsdt: 100));

      expect(find.text('Fecha'), findsOneWidget);
      expect(
          find.text(
              DateFormat('yyyy-MM-dd HH:mm:ss').format(created.toLocal())),
          findsOneWidget);
      // 12.521 sats at a 5% commission: 13.147 bought, with the 21 of network
      // fee and the 12.500 the customer got.
      expect(find.text('13.147 SAT'), findsOneWidget);
      expect(find.text('21 SAT'), findsOneWidget);
      expect(find.text('12.500 SAT'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('SETTLED_TO_BALANCE', () {
    testWidgets('says the sats were not sent and where the money is',
        (tester) async {
      await show(tester, _settled);

      expect(find.text('No se pudieron enviar los sats'), findsOneWidget);
      expect(find.text('El monto quedó en tu saldo de Wapu.'), findsOneWidget);
      expect(find.textContaining('La orden expiró'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('shows the receipt of the order, credited to the balance',
        (tester) async {
      await show(tester, _settled);

      expect(receipt, findsOneWidget);
      expect(find.text('Estado'), findsOneWidget);
      expect(find.text('Acreditada en saldo Wapu'), findsOneWidget);
      expect(find.text('Monto'), findsOneWidget);
      expect(find.text('Comprado'), findsNothing);
      expect(find.text('Depósito del cliente'), findsOneWidget);
      expect(find.text('15.000,37 ARS'), findsOneWidget);
      expect(find.text(_id), findsOneWidget);
      expect(newSaleBig, findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('when the invoice expired, names the Wapu account',
        (tester) async {
      await show(tester, _settledInvoiceExpired, wapuUser: 'ShopUser');

      const message = '$_invoiceExpired la cuenta de Wapu ShopUser';
      expect(find.text(message), findsOneWidget);
      // The username keeps its case: it is read out, not styled.
      expect(drawn(tester, find.text(message)), message);
      expect(find.text('No se pudieron enviar los sats'), findsNothing);
      expect(find.text('El monto quedó en tu saldo de Wapu.'), findsNothing);
      expect(receipt, findsOneWidget);
      expect(find.text('Acreditada en saldo Wapu'), findsOneWidget);
      expect(find.text('Depósito del cliente'), findsOneWidget);
      expect(newSaleBig, findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('when the invoice expired and the account is not known yet',
        (tester) async {
      await show(tester, _settledInvoiceExpired);

      expect(find.text('$_invoiceExpired tu cuenta de Wapu.'), findsOneWidget);
      expect(find.textContaining('la cuenta de Wapu'), findsNothing);
      expect(find.text('No se pudieron enviar los sats'), findsNothing);
      expect(receipt, findsOneWidget);
      expect(newSaleBig, findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('with any other error code keeps the usual message',
        (tester) async {
      for (final code in ['payout_failed', null]) {
        await show(
            tester,
            _order(
                status: 'SETTLED_TO_BALANCE',
                payoutStatus: 'settled_to_balance',
                watchPending: false,
                errorCode: code),
            wapuUser: 'ShopUser');

        expect(find.text('No se pudieron enviar los sats'), findsOneWidget,
            reason: '$code');
        expect(find.text('El monto quedó en tu saldo de Wapu.'), findsOneWidget,
            reason: '$code');
        expect(find.textContaining('ShopUser'), findsNothing, reason: '$code');
        expect(receipt, findsOneWidget, reason: '$code');
      }
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('any other status', () {
    testWidgets('shows the status as the backend wrote it', (tester) async {
      await show(
          tester,
          _order(
              status: 'CANCELLED',
              payoutStatus: 'cancelled',
              watchPending: false));

      expect(find.text('CANCELLED'), findsOneWidget);
      expect(newSaleBig, findsNothing);
      expect(fund, findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('bank rows', () {
    for (final (state, order) in [
      ('CREATED', _created),
      ('EXPIRED', _expired),
      ('EXECUTED sending', _sending),
      ('EXECUTED review', _review),
      ('COMPLETED', _completed),
      ('SETTLED_TO_BALANCE', _settled),
    ]) {
      testWidgets('$state shows none: its order has no alias or CVU',
          (tester) async {
        await show(tester, order);

        expect(find.text('Alias'), findsNothing);
        expect(find.text('CVU'), findsNothing);
        expect(find.text('Monto exacto'), findsNothing);
        expect(find.text('Copiar'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      });
    }
  });

  group('Nueva venta', () {
    for (final (state, order) in [
      ('COMPLETED', _completed),
      ('SETTLED_TO_BALANCE', _settled),
      ('a closed EXPIRED order', _expired),
      ('a CREATED order past its expiry', _createdPastExpiry),
      (
        'a FUNDING_ISSUED order past its expiry that is no longer watched',
        _order(
            alias: _alias,
            cvu: _cvu,
            watchPending: false,
            expiresAt: _now.subtract(const Duration(seconds: 3))),
      ),
    ]) {
      testWidgets('$state offers it, and it starts the next sale',
          (tester) async {
        var started = 0;
        await show(tester, order, onNewSale: () => started++);

        expect(find.text('Nueva venta'), findsOneWidget);
        expect(tester.widget<FilledButton>(newSaleBig).onPressed, isNotNull);

        await tester.ensureVisible(newSaleBig);
        await tester.tap(newSaleBig);
        expect(started, 1);
        await tester.pumpWidget(const SizedBox());
      });
    }

    for (final (state, order) in [
      ('FUNDING_ISSUED', _waiting),
      ('CREATED', _created),
      ('EXPIRED with the late watch on', _lateWatch),
      ('FUNDING_ISSUED past its expiry, still watched', _waitingPastExpiry),
      ('EXECUTED sending', _sending),
      ('EXECUTED review', _review),
    ]) {
      testWidgets('$state does not: the app bar has it', (tester) async {
        await show(tester, order);

        expect(newSaleBig, findsNothing);
        expect(find.text('Nueva venta'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      });
    }
  });

  group('in English', () {
    for (final (state, order, lines) in [
      (
        'FUNDING_ISSUED',
        _waiting,
        [
          'Waiting for the transfer',
          'Alias',
          'Exact amount',
          'Transfer exactly this amount, including the cents',
          'Expires in 14:59',
        ]
      ),
      ('CREATED', _created, ['Order created', 'Request transfer details']),
      (
        'EXPIRED with the late watch on',
        _lateWatch,
        [
          'Order expired',
          'No ARS was received and no sats were sent.',
          'If the customer already transferred, '
              'we keep looking until $_lateWatchClock',
          'Expired',
          'Expected deposit',
        ]
      ),
      (
        'FUNDING_ISSUED past its expiry',
        _waitingPastExpiry,
        [
          'Order expired',
          'No ARS was received and no sats were sent.',
          'If the customer already transferred, '
              'we keep looking until $_lateWatchClock',
        ]
      ),
      (
        'a closed EXPIRED order',
        _expired,
        [
          'Order expired',
          'No ARS was received and no sats were sent.',
          'Amount',
          'Status',
          'Expired',
          'Expected deposit',
          'New sale',
        ]
      ),
      ('EXECUTED sending', _sending, ['Payment received', 'Sending the sats…']),
      ('EXECUTED review', _review, ['Under review', 'Save the order ID: $_id']),
      (
        'COMPLETED',
        _completed,
        ['Done! The customer received 12.500 sats', 'New sale']
      ),
      (
        'SETTLED_TO_BALANCE',
        _settled,
        [
          'The sats could not be sent',
          'The amount went to your Wapu balance.',
          'Credited to Wapu balance',
          'New sale',
        ]
      ),
      (
        'SETTLED_TO_BALANCE with an expired invoice',
        _settledInvoiceExpired,
        [
          'The order expired but the ARS deposit was detected; '
              'the balance was credited to your Wapu account.',
          'Credited to Wapu balance',
          'New sale',
        ]
      ),
    ]) {
      testWidgets('$state is translated', (tester) async {
        await show(tester, order, english: true);

        for (final line in lines) {
          expect(find.text(line), findsOneWidget, reason: line);
        }
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('the message of an expired invoice names the account',
        (tester) async {
      await show(tester, _settledInvoiceExpired,
          english: true, wapuUser: 'ShopUser');

      expect(
          find.text('The order expired but the ARS deposit was detected; '
              'the balance was credited to the Wapu account ShopUser'),
          findsOneWidget);
      expect(find.text('Credited to Wapu balance'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the copy buttons and what they say are translated',
        (tester) async {
      await show(tester, _waiting, english: true);
      expect(find.text('Copy'), findsNWidgets(2));

      await tester.tap(find.byKey(const Key('wapu-copy-alias')));
      await tester.pump();

      expect(copied, _alias, reason: 'the value is never translated');
      expect(find.text('Copied'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('on the till screen', () {
    /// The Z92: 720x1280 at 1.5, with the app's 1.3 text scale (lib/app.dart).
    Future<void> showOnTill(WidgetTester tester, WapuOrder order,
        {Size size = const Size(720, 1280)}) async {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1.5;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Scaffold(body: WapuStatusView(order: order, now: _now)),
      ));
      await tester.pump();
    }

    const longAlias = 'una.alias.muy.larga.que.tiene.que.partirse.en.lineas';

    testWidgets('wraps long values inside the width', (tester) async {
      await showOnTill(
          tester,
          _order(
              alias: longAlias,
              cvu: _cvu,
              expiresAt: _now.add(const Duration(minutes: 15))));

      expect(tester.takeException(), isNull);
      for (final value in [longAlias]) {
        // A selection over the whole text has one box per line.
        final lines = tester
            .renderObject<RenderParagraph>(find.descendant(
                of: find.text(value), matching: find.byType(RichText)))
            .getBoxesForSelection(
                TextSelection(baseOffset: 0, extentOffset: value.length));
        expect(lines.length, greaterThan(1), reason: '$value wraps');
        expect(tester.getSize(find.text(value)).width, lessThan(480));
      }
      for (final key in ['alias', 'amount']) {
        final button = find.byKey(Key('wapu-copy-$key'));
        expect(tester.getRect(button).right, lessThanOrEqualTo(480),
            reason: key);
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('scrolls on a short screen instead of overflowing',
        (tester) async {
      await showOnTill(tester, _waiting, size: const Size(720, 450)); // 300 dp

      final content = find
          .descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(Column))
          .first;
      expect(tester.getSize(content).height, greaterThan(300),
          reason: 'taller than the screen');
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('Vence en 14:59'), 100);
      expect(find.text('Vence en 14:59'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the big Nueva venta button is large', (tester) async {
      await showOnTill(tester, _completed);

      expect(tester.getSize(newSaleBig).height, greaterThanOrEqualTo(74));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an expired order fits, with its notes and its receipt',
        (tester) async {
      for (final order in [_lateWatch, _waitingPastExpiry, _expired]) {
        await showOnTill(tester, order);

        expect(tester.takeException(), isNull);
        expect(tester.getRect(receipt).right, lessThanOrEqualTo(480));
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the receipt fits the width and scrolls on a short screen',
        (tester) async {
      await showOnTill(tester, _completed,
          size: const Size(720, 450)); // 300 dp

      expect(tester.takeException(), isNull);
      expect(tester.getRect(receipt).right, lessThanOrEqualTo(480));
      // The id is selectable text, which scrolls on its own: the view's is first.
      await tester.scrollUntilVisible(newSaleBig, 100,
          scrollable: find.byType(Scrollable).first);
      expect(newSaleBig, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
