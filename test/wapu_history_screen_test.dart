import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lawallet_pos/core/flow_lock.dart';
import 'package:lawallet_pos/core/i18n.dart';
import 'package:lawallet_pos/core/router.dart';
import 'package:lawallet_pos/core/sounds.dart';
import 'package:lawallet_pos/core/theme.dart';
import 'package:lawallet_pos/core/ui.dart' as ui;
import 'package:lawallet_pos/data/lnurl/lnurl_service.dart';
import 'package:lawallet_pos/domain/config/miniapp_pin.dart';
import 'package:lawallet_pos/domain/config/session.dart';
import 'package:lawallet_pos/domain/config/settings_state.dart';
import 'package:lawallet_pos/features/wapu/wapu_account.dart';
import 'package:lawallet_pos/features/wapu/wapu_api.dart';
import 'package:lawallet_pos/features/wapu/wapu_history_screen.dart';
import 'package:lawallet_pos/features/wapu/wapu_screen.dart';
import 'package:lawallet_pos/features/wapu/wapu_status_view.dart'
    show WapuStatusView;

const _me = 'shop@lacrypta.ar';
const _other = 'other@lacrypta.ar';

const _signIn = 'Ingresá con la dirección del comercio para usar Wapu';
const _configure = 'Configurá tu API key de Wapu';
const _empty = 'Todavía no hay órdenes';
const _timedOut = 'El servidor no respondió. Probá de nuevo.';

const _tentatives = '/transactions/direct-fiat/tentatives';
const _listRoute = 'GET $_tentatives';

const _profileRoute = 'GET /users/profile';

/// The message of an order credited to the balance after its invoice expired,
/// up to the account: its username follows, or `tu cuenta de Wapu.` when the
/// username is not known.
const _expiredInvoice = 'La orden expiró pero se detectó el depósito en ARS, '
    'el saldo fue acreditado en';

/// The route that reads the order [id] on its own.
String _read(String id) => 'GET $_tentatives/$id';

const _cvu = '0000003100012345678901';
const _hash =
    '3f9a1c0be2d84a76b5c3d1e0f9a8b7c6d5e4f30211223344556677889900aabb';

/// Answers each WapuPay request with [routes]`[METHOD path]` → (status, body).
class FakeNet implements HttpClientAdapter {
  FakeNet(this.routes);
  final Map<String, (int, Object)> routes;
  final calls = <String>[];

  /// Routes that fail as a transport error instead of answering.
  final failures = <String, DioException>{};

  /// Holds each request until the future it returns completes, when set. The
  /// answer is the one routed when the request came in, not when it is let go.
  Future<void> Function(RequestOptions o)? hold;

  @override
  Future<ResponseBody> fetch(
      RequestOptions o, Stream<Uint8List>? _, Future<void>? __) async {
    final key = '${o.method} ${o.uri.path}';
    calls.add(key);
    final failure = failures[key];
    final (code, body) = routes[key] ?? (404, {'error': 'nope'});
    await hold?.call(o);
    if (failure != null) throw failure;
    return ResponseBody.fromString(jsonEncode(body), code, headers: {
      'content-type': ['application/json']
    });
  }

  @override
  void close({bool force = false}) {}
}

/// Takes every address: the sale after a Nueva venta needs no network.
class FakeLnurl extends LnurlService {
  @override
  Future<void> validate(String address) async {}
}

/// Answers [load] for the merchants in [holds] only when their completer does.
class SlowAccounts extends WapuAccounts {
  final holds = <String, Completer<WapuCredentials?>>{};

  @override
  Future<WapuCredentials?> load(String merchantAddress) =>
      holds[merchantAddress]?.future ?? super.load(merchantAddress);
}

/// An API whose list of orders fails in a way the client never reports.
class BrokenOrdersApi extends WapuApi {
  BrokenOrdersApi() : super(baseUrl: kWapuDefaultBaseUrl, apiKey: 'key-1');

  @override
  Future<List<WapuOrder>> orders() => Future.error(StateError('boom'));
}

/// A device that already holds a key for each merchant of [keys].
void seed(Map<String, String> keys) =>
    FlutterSecureStorage.setMockInitialValues({
      'wapu.accounts': jsonEncode({
        for (final e in keys.entries)
          e.key: {'apiKey': e.value, 'baseUrl': kWapuDefaultBaseUrl},
      }),
    });

/// One order as the backend sends it: by default one that waits for the
/// transfer, with the bank details `alias.<id>` and [_cvu]. Only an order that
/// waits for the transfer, or waits late, has them.
Map<String, Object?> orderJson(
  String id, {
  String status = 'FUNDING_ISSUED',
  String payout = 'waiting_ars',
  bool watch = true,
  String address = 'alice@example.com',
  int ars = 1500037,
  int out = 12500,
  Duration expiresIn = const Duration(minutes: 15),
  String? hash,
  String? created,
  String? error,
}) {
  final bank = status == 'FUNDING_ISSUED' || (status == 'EXPIRED' && watch);
  return {
    'tentative_id': id,
    'type': 'crypto_purchase',
    'status': status,
    'payout_status': payout,
    'payout_address': address,
    'amount_ars_cents': ars,
    'amount_out': out,
    'network_fee_out': 21,
    if (created != null) 'created_at': created,
    'expires_at': DateTime.now().toUtc().add(expiresIn).toIso8601String(),
    'late_watch_until': null,
    'watch_pending': watch,
    if (bank) 'alias': 'alias.$id',
    if (bank) 'cvu': _cvu,
    'payment_hash': hash,
    'error_code': error,
  };
}

/// An order that was sent and received.
Map<String, Object?> doneJson(String id, {int out = 17000, String? created}) =>
    orderJson(id,
        status: 'COMPLETED',
        payout: 'completed',
        watch: false,
        hash: _hash,
        out: out,
        ars: 2000000,
        address: 'carol@example.com',
        created: created);

/// An order whose customer's invoice expired before the sats went out: the ARS
/// were credited to the merchant's Wapu balance.
Map<String, Object?> creditedJson(String id) => orderJson(id,
    status: 'SETTLED_TO_BALANCE',
    payout: 'settled_to_balance',
    watch: false,
    error: 'invoice_expired');

/// What the backend answers to the list of orders, in [orders]' order.
(int, Object) listReply(List<Map<String, Object?>> orders) =>
    (200, {'tentatives': orders});

/// The ids of the rows on screen, top to bottom.
List<String> rowIds(WidgetTester tester) => [
      for (final w in tester.widgetList(find.byWidgetPredicate((w) {
        final key = w.key;
        return key is ValueKey<String> && key.value.startsWith('wapu-order-');
      })))
        (w.key! as ValueKey<String>).value.substring('wapu-order-'.length),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final realLnurl = lnurl;
  final realAccounts = wapuAccounts;
  final realApiFor = wapuApiFor;
  late FakeNet net;

  final history = find.byKey(const Key('wapu-history'));
  final retry = find.byKey(const Key('wapu-history-retry'));
  final destination = find.byKey(const Key('wapu-destination'));
  final next = find.byKey(const Key('wapu-continue'));
  final newSale = find.byKey(const Key('wapu-new-sale'));
  Finder row(String id) => find.byKey(Key('wapu-order-$id'));

  setUp(() {
    seed({_me: 'key-1'});
    lnurl = FakeLnurl();
    net = FakeNet({});
    wapuApiFor = (baseUrl, apiKey) => WapuApi(
        baseUrl: baseUrl, apiKey: apiKey, dio: Dio()..httpClientAdapter = net);
  });

  tearDown(() {
    lockedFlow.value = null;
    miniappPin.value = null;
    lnurl = realLnurl;
    merchantAddress.value = '';
    wapuAccounts = realAccounts;
    wapuApiFor = realApiFor;
  });

  /// Lets the storage and the fake network answer (Dio hops through zero-delay
  /// timers, which a bare pump() does not fire) and a route finish moving. Not
  /// pumpAndSettle: a spinner on screen never settles.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Pumps the sale at /wapu behind the till's lock redirect, on the Z92's
  /// portrait screen (a taller one when the test reads many rows, which a list
  /// builds only as far as it shows), signed in as [merchant] (nobody, when
  /// empty). [at] is where the app starts: the History is a route on top of
  /// the sale.
  Future<void> open(WidgetTester tester,
      {String merchant = _me,
      bool english = false,
      String at = '/wapu',
      double height = 1440}) async {
    tester.view
      ..physicalSize = Size(720, height)
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    merchantAddress.value = merchant;
    final router = GoRouter(
      initialLocation: at,
      redirect: (c, s) => lockRedirect(s.uri.path),
      routes: [
        GoRoute(path: '/hub', builder: (_, __) => const Text('hub')),
        GoRoute(
          path: '/wapu',
          builder: (_, __) => const WapuScreen(),
          routes: [
            GoRoute(
              path: 'historial',
              builder: (_, __) => const WapuHistoryScreen(),
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(
      theme: buildAppTheme(),
      locale: english ? const Locale('en') : null,
      localizationsDelegates:
          english ? const [AppLocalizationsDelegate()] : null,
      // The app scales its text by 1.3 (lib/app.dart).
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.3)),
        child: child!,
      ),
      routerConfig: router,
    ));
    await settle(tester);
  }

  /// The sale, then the History from its app bar.
  Future<void> openHistory(WidgetTester tester, {bool english = false}) async {
    await open(tester, english: english);
    await tester.tap(history);
    await settle(tester);
  }

  /// How many times the till called [route].
  int calls(String route) => net.calls.where((c) => c == route).length;

  /// Holds the requests to [path] until the returned completer completes.
  Completer<void> holdOn(String method, String path) {
    final held = Completer<void>();
    net.hold = (o) => o.method == method && o.uri.path == path
        ? held.future
        : Future.value();
    return held;
  }

  group('history', () {
    testWidgets('lists in-progress orders first', (tester) async {
      net.routes[_listRoute] = listReply([
        orderJson('a', status: 'COMPLETED', payout: 'completed', watch: false),
        orderJson('b'),
        orderJson('c', status: 'EXPIRED'), // the late watch is still on
      ]);
      await openHistory(tester);

      expect(rowIds(tester), ['b', 'c', 'a']);
      expect(find.text('Historial'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('keeps the order of the API within each group',
        (tester) async {
      net.routes[_listRoute] = listReply([
        orderJson('d', status: 'COMPLETED', payout: 'completed', watch: false),
        orderJson('e'),
        orderJson('f', status: 'EXPIRED', watch: false),
        // Not watched, but its window is still open.
        orderJson('g',
            status: 'CREATED',
            watch: false,
            expiresIn: const Duration(minutes: 5)),
        orderJson('h'),
      ]);
      await openHistory(tester);

      expect(rowIds(tester), ['e', 'g', 'h', 'd', 'f']);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('empty history', (tester) async {
      net.routes[_listRoute] = listReply([]);
      await openHistory(tester);

      expect(find.text(_empty), findsOneWidget);
      expect(rowIds(tester), isEmpty);
      expect(retry, findsNothing, reason: 'nothing went wrong');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('asks the account of the signed-in user', (tester) async {
      seed({_me: 'key-1', _other: 'key-2'});
      final keys = <String>[];
      wapuApiFor = (baseUrl, apiKey) {
        keys.add(apiKey);
        return WapuApi(
            baseUrl: baseUrl,
            apiKey: apiKey,
            dio: Dio()..httpClientAdapter = net);
      };
      net.routes[_listRoute] = listReply([orderJson('b')]);

      await open(tester, merchant: _other);
      await tester.tap(history);
      await settle(tester);

      expect(rowIds(tester), ['b']);
      // The sale builds a client of its own too: every one has their key.
      expect(keys, isNotEmpty);
      expect(keys.toSet(), {'key-2'}, reason: "their key, not another's");
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a revoked key shows the invalid-key message', (tester) async {
      net.routes[_listRoute] = (401, {'error': 'invalid api key'});
      await openHistory(tester);

      expect(find.text('La API key no es válida'), findsOneWidget);
      expect(find.text('invalid api key'), findsOneWidget,
          reason: "the backend's own words, under the copy");
      expect(find.text('Reintentar'), findsOneWidget);
      expect(find.text(_empty), findsNothing,
          reason: 'an error is not an empty history');
      expect(rowIds(tester), isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a reply without the list is an error, not an empty history',
        (tester) async {
      net.routes[_listRoute] = (200, {'data': []});
      await openHistory(tester);

      expect(find.text('No se pudo completar la operación'), findsOneWidget);
      expect(find.text('unexpected response'), findsOneWidget);
      expect(retry, findsOneWidget);
      expect(find.text(_empty), findsNothing,
          reason: 'an order whose create had no answer may be in the list');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failure of our own is an error too', (tester) async {
      wapuApiFor = (_, __) => BrokenOrdersApi();
      await openHistory(tester);

      expect(find.text('No se pudo completar la operación'), findsOneWidget);
      expect(find.textContaining('boom'), findsNothing);
      expect(retry, findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'it is not left loading');
      expect(find.text(_empty), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Reintentar reads the orders again', (tester) async {
      net.failures[_listRoute] = DioException(
          requestOptions: RequestOptions(),
          type: DioExceptionType.receiveTimeout);
      await openHistory(tester);
      expect(find.text(_timedOut), findsOneWidget);
      expect(retry, findsOneWidget);

      net.failures.clear();
      net.routes[_listRoute] = listReply([orderJson('b')]);
      final held = holdOn('GET', _tentatives);
      await tester.tap(retry);
      await tester.pump();
      expect(find.text(_timedOut), findsNothing,
          reason: 'it is being tried again');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      held.complete();
      await settle(tester);
      expect(rowIds(tester), ['b']);
      expect(retry, findsNothing);
      expect(calls(_listRoute), 2);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('without a key it says so, and Reintentar finds one saved',
        (tester) async {
      seed({}); // the route is reachable on its own, whatever the sale says
      net.routes[_listRoute] = listReply([orderJson('b')]);
      await open(tester, at: '/wapu/historial');

      expect(find.byType(WapuHistoryScreen), findsOneWidget);
      expect(find.text(_configure), findsOneWidget);
      expect(find.text(_empty), findsNothing);
      expect(calls(_listRoute), 0, reason: 'there is no key to ask with');

      seed({_me: 'key-1'});
      await tester.tap(retry);
      await settle(tester);
      expect(rowIds(tester), ['b']);
      expect(find.text(_configure), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a row shows the amount, the sats, the address and its state',
        (tester) async {
      net.routes[_listRoute] = listReply([
        orderJson('b'),
        orderJson('g',
            status: 'CREATED',
            watch: false,
            expiresIn: const Duration(minutes: 5)),
        doneJson('a'),
        orderJson('d', status: 'EXPIRED', watch: false),
        // Never funded, and its window has closed.
        orderJson('e',
            status: 'CREATED',
            watch: false,
            expiresIn: const Duration(minutes: -1)),
        orderJson('f',
            status: 'SETTLED_TO_BALANCE',
            payout: 'settled_to_balance',
            watch: false),
        orderJson('h', status: 'EXECUTED', payout: 'review', watch: false),
      ]);
      await open(tester, height: 4000);
      await tester.tap(history);
      await settle(tester);
      expect(rowIds(tester), hasLength(7));

      Finder inRow(String id, String text) =>
          find.descendant(of: row(id), matching: find.text(text));
      expect(inRow('b', r'$ 15.000,37'), findsOneWidget);
      expect(inRow('b', '12.500 sats'), findsOneWidget);
      expect(inRow('b', 'alice@example.com'), findsOneWidget);
      expect(inRow('a', r'$ 20.000,00'), findsOneWidget);
      expect(inRow('a', '17.000 sats'), findsOneWidget);
      expect(inRow('a', 'carol@example.com'), findsOneWidget);
      for (final (id, label) in [
        ('b', 'En curso'),
        ('g', 'En curso'),
        ('a', 'Completada'),
        ('d', 'Vencida'),
        ('e', 'Vencida'),
        ('f', 'En tu saldo'),
        ('h', 'EXECUTED'), // what is not known is said as the backend says it
      ]) {
        expect(inRow(id, label), findsOneWidget, reason: id);
      }
      for (final text in [r'$ 15.000,37', '12.500 sats', 'alice@example.com']) {
        expect(tester.widget(inRow('b', text)), isNot(isA<ui.Text>()),
            reason: '$text must not be uppercased or squeezed onto one line');
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a long address wraps and is shown whole', (tester) async {
      const long = 'una.direccion.muy.larga.de.un.cliente.con.nombre.largo'
          '@un-dominio-de-prueba-bastante-largo.example.com';
      net.routes[_listRoute] = listReply([orderJson('b', address: long)]);
      await openHistory(tester);

      expect(find.text(long), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'no overflow');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an invoice is shown short, as the receipt shows it',
        (tester) async {
      const invoice = 'lnbc25u1p3xyzabcdefghijklmnopqrstuvwxyz0123456789';
      net.routes[_listRoute] = listReply([orderJson('b', address: invoice)]);
      await openHistory(tester);

      expect(find.text('lnbc25u1p3xy…23456789'), findsOneWidget);
      expect(find.text(invoice), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the history is translated', (tester) async {
      net.routes[_listRoute] = listReply([
        orderJson('b'),
        doneJson('a'),
        orderJson('d', status: 'EXPIRED', watch: false),
        orderJson('f',
            status: 'SETTLED_TO_BALANCE',
            payout: 'settled_to_balance',
            watch: false),
      ]);
      await open(tester, english: true);
      expect(find.byTooltip('HISTORY'), findsOneWidget);
      await tester.tap(history);
      await settle(tester);

      expect(find.text('History'), findsOneWidget);
      expect(find.text('In progress'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('Expired'), findsOneWidget);
      expect(find.text('In your balance'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the empty history and the retry are translated',
        (tester) async {
      net.routes[_listRoute] = (503, {'error': 'down'});
      await openHistory(tester, english: true);
      expect(find.text('Retry'), findsOneWidget);

      net.routes[_listRoute] = listReply([]);
      await tester.tap(retry);
      await settle(tester);
      expect(find.text('There are no orders yet'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('the history action', () {
    testWidgets('is offered to a signed-in user with a key', (tester) async {
      await open(tester);

      expect(history, findsOneWidget);
      expect(find.byTooltip('HISTORIAL'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('is not offered when nobody is signed in', (tester) async {
      await open(tester, merchant: '');

      expect(find.text(_signIn), findsOneWidget);
      expect(history, findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('is not offered without a key', (tester) async {
      seed({});
      await open(tester);

      expect(find.text(_configure), findsOneWidget);
      expect(history, findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('waits for the key to be read', (tester) async {
      final slow = SlowAccounts();
      slow.holds[_me] = Completer();
      wapuAccounts = slow;
      await open(tester);
      expect(history, findsNothing, reason: 'the key is not known yet');

      slow.holds[_me]!.complete(const WapuCredentials(apiKey: 'key-1'));
      await settle(tester);
      expect(history, findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('history is reachable while locked', (tester) async {
      net.routes[_listRoute] = listReply([orderJson('b')]);
      net.routes[_read('b')] = (200, orderJson('b'));
      lockedFlow.value = '/wapu';
      expect(lockRedirect('/wapu/historial'), isNull);
      expect(lockRedirect('/orders'), '/wapu', reason: 'the lock is on');

      await open(tester);
      expect(history, findsOneWidget);
      await tester.tap(history);
      await settle(tester);
      expect(find.byType(WapuHistoryScreen), findsOneWidget,
          reason: 'not sent back to the sale');
      expect(rowIds(tester), ['b']);

      await tester.tap(find.byIcon(Icons.arrow_back));
      await settle(tester);
      expect(find.byType(WapuHistoryScreen), findsNothing,
          reason: 'and not stuck there');

      await tester.tap(history);
      await settle(tester);
      await tester.tap(row('b'));
      await settle(tester);
      expect(find.text('alias.b'), findsOneWidget);
      expect(lockedFlow.value, '/wapu', reason: 'still locked');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("the app's own router serves it and hands the order back",
        (tester) async {
      net.routes[_listRoute] = listReply([orderJson('b')]);
      net.routes[_read('b')] = (200, orderJson('b'));
      tester.view
        ..physicalSize = const Size(720, 1440)
        ..devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      merchantAddress.value = _me;
      appRouter.go('/wapu');
      await tester.pumpWidget(
          MaterialApp.router(theme: buildAppTheme(), routerConfig: appRouter));
      await settle(tester);

      await tester.tap(history);
      await settle(tester);
      expect(find.byType(WapuHistoryScreen), findsOneWidget);
      await tester.tap(row('b'));
      await settle(tester);

      expect(find.byType(WapuHistoryScreen), findsNothing);
      expect(find.text('alias.b'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('resume', () {
    /// What the till asked the speaker to play, by name.
    final played = <String>[];

    setUp(() async {
      played.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('pos/sounds'),
              (call) async {
        if (call.method == 'play') {
          played.add((call.arguments as Map)['name'] as String);
        }
        return null;
      });
      appSettings.value = const SettingsState();
      await AppSounds.prepare();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('pos/sounds'), null);
    });

    /// Opens the History and taps the order [id].
    Future<void> pick(WidgetTester tester, String id) async {
      await tester.tap(history);
      await settle(tester);
      await tester.tap(row(id));
      await settle(tester);
    }

    testWidgets('tapping an order resumes it on the sale screen',
        (tester) async {
      net.routes[_listRoute] = listReply([doneJson('a'), orderJson('b')]);
      net.routes[_read('b')] = (200, orderJson('b'));
      await open(tester);

      await pick(tester, 'b');

      expect(find.byType(WapuHistoryScreen), findsNothing);
      expect(destination, findsNothing, reason: 'the order, not the first step');
      expect(find.text('Esperando la transferencia'), findsOneWidget);
      expect(find.text('alias.b'), findsOneWidget);
      expect(find.text(r'$ 15.000,37'), findsOneWidget);
      expect(calls(_read('b')), 1);

      await tester.pump(const Duration(seconds: 10));
      expect(calls(_read('b')), 2, reason: 'followed like a new order');
      expect(calls(_read('a')), 0, reason: 'only the order that was chosen');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a finished order has no bank details, polling or cue',
        (tester) async {
      net.routes[_listRoute] = listReply([doneJson('a')]);
      net.routes[_read('a')] = (200, doneJson('a'));
      await open(tester);

      await pick(tester, 'a');

      expect(find.text('¡Listo! El cliente recibió 17.000 sats'),
          findsOneWidget);
      expect(find.text(_hash), findsNothing,
          reason: 'the receipt has the order id, not the payment hash');
      expect(find.text('alias.a'), findsNothing);
      await tester.pump(const Duration(seconds: 30));
      expect(calls(_read('a')), 1, reason: 'nothing is left to wait for');
      expect(played.where((n) => n == 'arpeggio'), isEmpty,
          reason: 'nothing was paid just now');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a completed order from the History shows its receipt',
        (tester) async {
      const created = '2026-10-29T16:50:34Z';
      final clock = DateFormat('yyyy-MM-dd HH:mm:ss')
          .format(DateTime.utc(2026, 10, 29, 16, 50, 34).toLocal());
      net.routes[_listRoute] =
          listReply([doneJson('a', created: created), orderJson('b')]);
      net.routes[_read('a')] = (200, doneJson('a', created: created));
      await open(tester);

      await pick(tester, 'a');

      expect(find.byKey(const Key('wapu-receipt')), findsOneWidget);
      for (final text in [
        'Comprado',
        '17.000 SAT',
        'Fecha',
        clock,
        'Completada',
        'carol@example.com',
        'a', // the id
        'Comisión de la operación',
        '21 SAT',
        'Depósito del cliente',
        '20.000,00 ARS',
        'Total',
        '17.021 SAT',
      ]) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an order credited after its invoice expired names the account',
        (tester) async {
      net.routes[_listRoute] =
          listReply([creditedJson('f'), creditedJson('g')]);
      net.routes[_read('f')] = (200, creditedJson('f'));
      net.routes[_read('g')] = (200, creditedJson('g'));
      net.routes[_profileRoute] = (200, {'username': 'ShopUser'});
      await open(tester);

      await pick(tester, 'f');

      const message = '$_expiredInvoice la cuenta de Wapu ShopUser';
      expect(find.text(message), findsOneWidget);
      expect(find.text('No se pudieron enviar los sats'), findsNothing);
      expect(find.byKey(const Key('wapu-receipt')), findsOneWidget);
      expect(find.text('Acreditada en saldo Wapu'), findsOneWidget);
      expect(find.text('f'), findsOneWidget, reason: 'its id, in the receipt');
      expect(calls(_profileRoute), 1);
      expect(find.byKey(const Key('wapu-new-sale-big')), findsOneWidget);
      await tester.pump(const Duration(seconds: 30));
      expect(calls(_read('f')), 1, reason: 'nothing is left to wait for');

      // Another credited order of the same account: its name is known.
      await pick(tester, 'g');

      expect(find.text(message), findsOneWidget);
      expect(find.text('g'), findsOneWidget);
      expect(calls(_profileRoute), 1, reason: 'asked once for the key');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a credited order says "tu cuenta" when the profile fails',
        (tester) async {
      net.routes[_listRoute] = listReply([creditedJson('f')]);
      net.routes[_read('f')] = (200, creditedJson('f'));
      net.routes[_profileRoute] = (500, {'error': 'boom'});
      await open(tester);

      await pick(tester, 'f');

      expect(find.text('$_expiredInvoice tu cuenta de Wapu.'), findsOneWidget);
      expect(find.byKey(const Key('wapu-receipt')), findsOneWidget);
      expect(find.text('No se pudo completar la operación'), findsNothing);
      expect(calls(_profileRoute), 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an expired order from the History shows its details',
        (tester) async {
      net.routes[_listRoute] =
          listReply([orderJson('d', status: 'EXPIRED', watch: false)]);
      net.routes[_read('d')] =
          (200, orderJson('d', status: 'EXPIRED', watch: false));
      await open(tester);

      await pick(tester, 'd');

      expect(find.text('Orden vencida'), findsOneWidget);
      expect(find.text('No se recibieron ARS ni se enviaron sats.'),
          findsOneWidget);
      expect(find.byKey(const Key('wapu-receipt')), findsOneWidget);
      expect(find.text('Vencida'), findsOneWidget);
      expect(find.text('Depósito esperado'), findsOneWidget);
      expect(find.byKey(const Key('wapu-new-sale-big')), findsOneWidget);
      await tester.pump(const Duration(seconds: 30));
      expect(calls(_read('d')), 1, reason: 'nothing is left to wait for');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an order past its window is expired, and is read, not ticked',
        (tester) async {
      // The backend still says FUNDING_ISSUED, and still watches it.
      net.routes[_listRoute] =
          listReply([orderJson('e', expiresIn: const Duration(minutes: -1))]);
      net.routes[_read('e')] =
          (200, orderJson('e', expiresIn: const Duration(minutes: -1)));
      await open(tester);

      await pick(tester, 'e');

      expect(find.text('Orden vencida'), findsOneWidget);
      expect(find.textContaining('Vence en'), findsNothing);
      expect(find.text('alias.e'), findsNothing);
      expect(find.byKey(const Key('wapu-receipt')), findsOneWidget);
      expect(find.byKey(const Key('wapu-new-sale-big')), findsNothing,
          reason: 'still watched: the app bar has Nueva venta');
      // No clock repaints it: its `now` stays while the polls come at 10 s.
      final view = find.byType(WapuStatusView);
      final last = tester.widget<WapuStatusView>(view).now;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(seconds: 5));
      expect(tester.widget<WapuStatusView>(view).now, last);
      expect(calls(_read('e')), 1);

      await tester.pump(const Duration(seconds: 5));
      expect(calls(_read('e')), 2, reason: 'it is still read');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an order that cannot be read is told on the first step',
        (tester) async {
      net.routes[_listRoute] = listReply([orderJson('b')]);
      await open(tester);

      var reads = 0;
      for (final (reply, copy) in [
        ((404, {'error': 'tentative not found'}), 'La orden no existe'),
        ((401, {'error': 'invalid api key'}), 'La API key no es válida'),
        ((500, {'error': 'internal error'}), 'No se pudo completar la operación'),
      ]) {
        net.routes[_read('b')] = reply;
        await pick(tester, 'b');
        reads++;

        expect(find.text(copy), findsOneWidget, reason: copy);
        expect(tester.getTopLeft(find.text(copy)).dy,
            greaterThan(tester.getBottomLeft(destination).dy),
            reason: 'under the field');
        expect(tester.widget<Text>(find.text(copy)).style?.color,
            AppColors.error);
        expect(find.byKey(const Key('wapu-error-detail')), findsNothing,
            reason: 'the copy alone, as on the other first-step errors');
        expect(destination, findsOneWidget);
        expect(tester.widget<TextField>(destination).enabled, isTrue,
            reason: 'it is not left waiting');
      }

      net.failures[_read('b')] = DioException(
          requestOptions: RequestOptions(),
          type: DioExceptionType.receiveTimeout);
      await pick(tester, 'b');
      reads++;
      expect(find.text(_timedOut), findsOneWidget);
      expect(destination, findsOneWidget);

      await tester.pump(const Duration(seconds: 30));
      expect(calls(_read('b')), reads, reason: 'a failed order is not polled');

      // The same order opens once it can be read.
      net.failures.clear();
      net.routes[_read('b')] = (200, orderJson('b'));
      await pick(tester, 'b');
      expect(find.text(_timedOut), findsNothing);
      expect(find.text('alias.b'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a resume that lands after Nueva venta is dropped',
        (tester) async {
      net.routes[_listRoute] = listReply([orderJson('b')]);
      net.routes[_read('b')] = (200, orderJson('b'));
      final held = holdOn('GET', '$_tentatives/b');
      await open(tester);

      await pick(tester, 'b');
      expect(calls(_read('b')), 1, reason: 'the read is on its way');
      expect(tester.widget<TextField>(destination).enabled, isFalse,
          reason: 'the first step waits for it');

      await tester.tap(newSale); // nothing is on screen to ask about
      await settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.widget<TextField>(destination).enabled, isTrue);

      held.complete(); // the order of the old pick arrives in the new sale
      await settle(tester);

      expect(destination, findsOneWidget, reason: 'the new sale did not move');
      expect(find.text('alias.b'), findsNothing);
      expect(find.text('Esperando la transferencia'), findsNothing);
      await tester.pump(const Duration(seconds: 30));
      expect(calls(_read('b')), 1, reason: 'nothing follows the dropped order');

      // And the new sale goes on as usual.
      await tester.enterText(destination, 'bob@example.com');
      await tester.tap(next);
      await settle(tester);
      expect(find.byKey(const Key('wapu-amount')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a resume replaces the order on screen and stops its clocks',
        (tester) async {
      net.routes[_listRoute] = listReply([orderJson('b'), orderJson('c')]);
      net.routes[_read('b')] = (200, orderJson('b'));
      net.routes[_read('c')] = (200, orderJson('c'));
      await open(tester);
      await pick(tester, 'b'); // b's clock reads it every 10 s
      expect(find.text('alias.b'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));

      await pick(tester, 'c');
      expect(find.text('alias.c'), findsOneWidget);
      expect(find.text('alias.b'), findsNothing);

      // b's clock would tick inside these 6 s; c's own is 10 s away.
      await tester.pump(const Duration(seconds: 6));
      expect(calls(_read('b')), 1, reason: 'b is not followed any more');
      expect(calls(_read('c')), 1);

      await tester.pump(const Duration(seconds: 5));
      expect(calls(_read('c')), 2, reason: 'c is');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('leaving the History without a choice keeps the sale',
        (tester) async {
      net.routes[_listRoute] = listReply([orderJson('b')]);
      await open(tester);
      await tester.enterText(destination, 'alice@example.com');

      await tester.tap(history);
      await settle(tester);
      expect(rowIds(tester), ['b']);
      await tester.tap(find.byIcon(Icons.arrow_back));
      await settle(tester);

      expect(find.byType(WapuHistoryScreen), findsNothing);
      expect(tester.widget<TextField>(destination).controller!.text,
          'alice@example.com');
      expect(net.calls.where((c) => c != _listRoute), isEmpty,
          reason: 'no order was opened');
      await tester.pumpWidget(const SizedBox());
    });
  });
}
