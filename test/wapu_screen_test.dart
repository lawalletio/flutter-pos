import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lawallet_pos/core/flow_lock.dart';
import 'package:lawallet_pos/core/i18n.dart';
import 'package:lawallet_pos/core/router.dart';
import 'package:lawallet_pos/core/sounds.dart';
import 'package:lawallet_pos/core/theme.dart';
import 'package:lawallet_pos/data/lnurl/lnurl_service.dart';
import 'package:lawallet_pos/domain/config/miniapp_pin.dart';
import 'package:lawallet_pos/domain/config/session.dart';
import 'package:lawallet_pos/domain/config/settings_state.dart';
import 'package:lawallet_pos/features/cards/cards_widgets.dart'
    show TokenScanPage;
import 'package:lawallet_pos/features/miniapps/miniapps.dart';
import 'package:lawallet_pos/features/wapu/wapu_account.dart';
import 'package:lawallet_pos/features/wapu/wapu_api.dart';
import 'package:lawallet_pos/features/wapu/wapu_screen.dart';
import 'package:lawallet_pos/features/wapu/wapu_settings_screen.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

const _me = 'shop@lacrypta.ar';
const _other = 'other@lacrypta.ar';

const _signIn = 'Ingresá con la dirección del comercio para usar Wapu';
const _configure = 'Configurá tu API key de Wapu';
const _invoiceHint =
    'Eso es un invoice. Pedile al cliente su lightning address';
const _lnurlHint = 'Eso es un LNURL. Pedile al cliente su lightning address';
const _notAnAddress = 'La lightning address no es válida';
const _unverified = 'No se pudo verificar la lightning address';

const _invoice = 'lnbc10u1p3xyz';
const _lnurl =
    'LNURL1DP68GURN8GHJ7UM5V93KKETJ9EHX2AMN9UH8WETVDSKKKMN0WAHZ7MRWW4'
    'EXCUP0DAJX2MRV92X9XP';

/// Answers each WapuPay request with [routes]`[METHOD path]` → (status, body).
class FakeNet implements HttpClientAdapter {
  FakeNet(this.routes);
  final Map<String, (int, Object)> routes;
  final calls = <String>[];

  /// The query of each of [calls].
  final queries = <Map<String, String>>[];

  /// The JSON body of each of [calls], or null when it sent none.
  final bodies = <Object?>[];

  /// The host each of [calls] went to.
  final hosts = <String>[];

  /// The API key each of [calls] carried.
  final keys = <Object?>[];

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
    hosts.add(o.uri.host);
    keys.add(o.headers['X-API-Key']);
    queries.add(o.uri.queryParameters);
    bodies.add(o.data is String ? jsonDecode(o.data as String) : null);
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

/// Resolves nothing: it records each address it is asked to validate, then
/// fails or waits when told to.
class FakeLnurl extends LnurlService {
  /// Thrown by [validate].
  Object? fail;

  /// Holds [validate] until it completes, when set.
  Completer<void>? hold;

  final validated = <String>[];

  @override
  Future<void> validate(String address) async {
    validated.add(address);
    await hold?.future;
    if (fail != null) throw fail!;
  }
}

/// Answers [load] for the merchants in [holds] only when their completer does.
class SlowAccounts extends WapuAccounts {
  final holds = <String, Completer<WapuCredentials?>>{};

  @override
  Future<WapuCredentials?> load(String merchantAddress) =>
      holds[merchantAddress]?.future ?? super.load(merchantAddress);
}

/// A camera that shows nothing and scans what the test hands it.
class FakeScanner extends MobileScannerPlatform {
  final scans = StreamController<BarcodeCapture?>.broadcast();

  @override
  Stream<BarcodeCapture?> get barcodesStream => scans.stream;
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();
  @override
  Widget buildCameraView() => const SizedBox.expand();
  @override
  Future<MobileScannerViewAttributes> start(StartOptions startOptions) async =>
      const MobileScannerViewAttributes(
          cameraDirection: CameraFacing.back,
          currentTorchMode: TorchState.unavailable,
          size: Size(720, 1280));
  @override
  Future<void> stop() async {}
  @override
  Future<void> updateScanWindow(Rect? window) async {}
  @override
  Future<void> dispose() async {}
}

/// A device that already holds a key for each merchant of [keys].
void seed(Map<String, String> keys) =>
    FlutterSecureStorage.setMockInitialValues({
      'wapu.accounts': jsonEncode({
        for (final e in keys.entries)
          e.key: {'apiKey': e.value, 'baseUrl': kWapuDefaultBaseUrl},
      }),
    });

const _quoteRoute = 'GET /transactions/direct-fiat/quote';

/// The backend's answer to a quote. By default $ 15.000 buys 12.500 sats, with
/// a 1,5% fee in the price, a $ 1.000 minimum and liquidity.
(int, Object) quoteReply({
  int ars = 1500000,
  int out = 12500,
  int min = 100000,
  bool liquidity = true,
}) =>
    (
      200,
      {
        'amount_ars_cents': ars,
        'amount_out': out,
        'network_fee_out': 21,
        'total_amount_usdt': 10000,
        'fee_amount_usdt': 150,
        'min_amount_ars_cents': min,
        'liquidity_ok': liquidity,
      }
    );

/// An API whose quote fails in a way the client never reports.
class BrokenApi extends WapuApi {
  BrokenApi() : super(baseUrl: kWapuDefaultBaseUrl, apiKey: 'key-1');

  @override
  Future<WapuQuote> quote({int? arsCents, int? sats}) =>
      Future.error(StateError('boom'));
}

/// An API that quotes as usual and whose create fails in a way the client never
/// reports.
class BrokenCreateApi extends WapuApi {
  BrokenCreateApi(Dio dio)
      : super(baseUrl: kWapuDefaultBaseUrl, apiKey: 'key-1', dio: dio);

  @override
  Future<WapuOrder> createOrder(
          {required String address, int? arsCents, int? sats}) =>
      Future.error(StateError('boom'));
}

const _tentatives = '/transactions/direct-fiat/tentatives';
const _createRoute = 'POST $_tentatives';
const _fundRoute = 'POST $_tentatives/t1/funding';
const _detailRoute = 'GET $_tentatives/t1';

const _alias = 'mi.alias.cobro';
const _cvu = '0000003100012345678901';
const _hash =
    '3f9a1c0be2d84a76b5c3d1e0f9a8b7c6d5e4f30211223344556677889900aabb';

/// The backend's answer for the order [id]: by default one that waits for the
/// transfer, funded at $ 15.000,37. Only the orders that have bank details send
/// them: pass [bank] false for the others.
(int, Object) orderReply({
  String id = 't1',
  String status = 'FUNDING_ISSUED',
  String payout = 'waiting_ars',
  bool watch = true,
  bool bank = true,
  String alias = _alias,
  int ars = 1500037,
  int code = 200,
  String? hash,
}) =>
    (
      code,
      {
        'tentative_id': id,
        'type': 'crypto_purchase',
        'status': status,
        'payout_status': payout,
        'payout_address': 'alice@example.com',
        'amount_ars_cents': ars,
        'amount_out': 12500,
        'network_fee_out': 21,
        'expires_at': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 15))
            .toIso8601String(),
        'late_watch_until': null,
        'watch_pending': watch,
        if (bank) 'alias': alias,
        if (bank) 'cvu': _cvu,
        'payment_hash': hash,
      }
    );

/// An order just created: the quoted amount, and no bank details yet.
(int, Object) createdReply({String id = 't1'}) => orderReply(
    id: id,
    status: 'CREATED',
    watch: false,
    bank: false,
    ars: 1500000,
    code: 201);

/// What the backend says once the transfer was seen and the sats went out.
(int, Object) completedReply() => orderReply(
    status: 'COMPLETED',
    payout: 'completed',
    watch: false,
    bank: false,
    hash: _hash);

/// The [value] on the quote line named [label].
Finder line(String label, String value) => find.descendant(
    of: find.widgetWithText(Wrap, label), matching: find.text(value));

/// Taps [digits] on the pad, one key at a time.
Future<void> typeDigits(WidgetTester tester, String digits) async {
  for (final d in digits.split('')) {
    await tester.tap(find.text(d));
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final realLnurl = lnurl;
  final realAccounts = wapuAccounts;
  final realApiFor = wapuApiFor;
  late FakeLnurl fake;
  late FakeScanner camera;
  late FakeNet net;

  final destination = find.byKey(const Key('wapu-destination'));
  final next = find.byKey(const Key('wapu-continue'));
  final gear = find.byKey(const Key('wapu-config'));
  final setup = find.byKey(const Key('wapu-setup'));
  final amount = find.byKey(const Key('wapu-amount'));
  final confirm = find.byKey(const Key('wapu-confirm'));
  final inSats = find.byKey(const Key('wapu-mode-sats'));
  final inArs = find.byKey(const Key('wapu-mode-ars'));
  final newSale = find.byKey(const Key('wapu-new-sale'));
  final history = find.byKey(const Key('wapu-history'));
  final fundButton = find.byKey(const Key('wapu-fund'));

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    fake = FakeLnurl();
    lnurl = fake;
    camera = FakeScanner();
    MobileScannerPlatform.instance = camera;
    // The config screen reads the account's beta flag with the saved key.
    net = FakeNet({
      'GET /users/user-settings': (200, {'beta_version': true}),
    });
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

  /// Pumps /wapu behind the till's lock redirect, on the Z92's portrait screen,
  /// signed in as [merchant] (nobody, when empty).
  Future<void> open(WidgetTester tester,
      {String merchant = _me, bool english = false}) async {
    tester.view
      ..physicalSize = const Size(720, 1440)
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    merchantAddress.value = merchant;
    final router = GoRouter(
      initialLocation: '/wapu',
      redirect: (c, s) => lockRedirect(s.uri.path),
      routes: [
        GoRoute(path: '/hub', builder: (_, __) => const Text('hub')),
        GoRoute(
          path: '/wapu',
          builder: (_, __) => const WapuScreen(),
          routes: [
            GoRoute(
                path: 'config', builder: (_, __) => const WapuSettingsScreen()),
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

  /// Types [text] into the destination field and taps Continuar.
  Future<void> submit(WidgetTester tester, String text) async {
    await tester.enterText(destination, text);
    await tester.tap(next);
    await settle(tester);
  }

  String fieldText(WidgetTester tester) =>
      tester.widget<TextField>(destination).controller!.text;

  Future<void> enterPin(WidgetTester tester, String pin) async {
    await tester.enterText(find.byKey(const Key('miniapp-pin')), pin);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
  }

  /// What the device holds for [merchant]. The storage mock answers on real
  /// async.
  Future<WapuCredentials?> stored(WidgetTester tester, String merchant) =>
      tester.runAsync<WapuCredentials?>(() => wapuAccounts.load(merchant));

  testWidgets('asks for a POS user first', (tester) async {
    await open(tester, merchant: '');

    expect(find.text(_signIn), findsOneWidget);
    expect(gear, findsNothing); // there is nobody to keep a key for
    expect(setup, findsNothing);
    expect(destination, findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('asks to configure when the merchant has no key', (tester) async {
    await open(tester);

    expect(find.text(_configure), findsOneWidget);
    expect(setup, findsOneWidget);
    expect(find.text('Configurar'), findsOneWidget);
    expect(gear, findsOneWidget);
    expect(destination, findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the gear asks for the PIN when one is set', (tester) async {
    miniappPin.value = '1234';
    seed({_me: 'key-1'});
    await open(tester);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget,
        reason: "ours is the only gear: the app bar's own has no PIN gate");

    await tester.tap(gear);
    await settle(tester);
    expect(find.byKey(const Key('miniapp-pin')), findsOneWidget);
    expect(find.byType(WapuSettingsScreen), findsNothing);

    await tester.tap(find.byKey(const Key('pin-cancel')));
    await settle(tester);
    expect(find.byKey(const Key('miniapp-pin')), findsNothing);
    expect(find.byType(WapuSettingsScreen), findsNothing);
    expect(destination, findsOneWidget, reason: 'still on /wapu');

    await tester.tap(gear);
    await settle(tester);
    await enterPin(tester, '0000');
    expect(find.byKey(const Key('miniapp-pin')), findsOneWidget,
        reason: 'a wrong PIN keeps asking');
    expect(find.byType(WapuSettingsScreen), findsNothing);

    await enterPin(tester, '1234');
    expect(find.byKey(const Key('miniapp-pin')), findsNothing);
    expect(find.byType(WapuSettingsScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the gear is hidden while locked', (tester) async {
    seed({_me: 'key-1'});
    lockedFlow.value = '/wapu';
    await open(tester);

    expect(gear, findsNothing);
    expect(find.byKey(const Key('flow-unlock')), findsOneWidget);
    expect(destination, findsOneWidget);

    lockedFlow.value = null;
    await tester.pump();
    expect(gear, findsOneWidget);

    await tester.tap(find.byKey(const Key('flow-lock'))); // the app bar's lock
    await tester.pump();
    expect(lockedFlow.value, '/wapu');
    expect(gear, findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rejects invoices and lnurls with a hint', (tester) async {
    seed({_me: 'key-1'});
    await open(tester);

    await submit(tester, _invoice);
    expect(find.text(_invoiceHint), findsOneWidget);

    await submit(tester, _lnurl);
    expect(find.text(_lnurlHint), findsOneWidget);
    expect(find.text(_invoiceHint), findsNothing, reason: 'one hint at a time');

    await submit(tester, 'hello');
    expect(find.text(_notAnAddress), findsOneWidget);
    expect(find.text(_lnurlHint), findsNothing);

    expect(fake.validated, isEmpty, reason: 'nothing was looked up');
    expect(destination, findsOneWidget, reason: 'still on the first step');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('normalizes and validates the address', (tester) async {
    seed({_me: 'key-1'});
    await open(tester);
    expect(find.text('nombre@dominio.com'), findsOneWidget);
    expect(find.text('Lightning address del cliente'), findsOneWidget);

    await submit(tester, '  LIGHTNING:Alice@Example.COM ');

    expect(fake.validated, ['alice@example.com']);
    expect(destination, findsNothing, reason: 'the step advanced');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("switching POS user resets to that user's state", (tester) async {
    seed({_me: 'key-1'});
    await open(tester);
    await tester.enterText(destination, 'alice@example.com');
    expect(destination, findsOneWidget);

    merchantAddress.value = _other; // has no key
    await settle(tester);
    expect(find.text(_configure), findsOneWidget);
    expect(setup, findsOneWidget);
    expect(destination, findsNothing);

    merchantAddress.value = ''; // signed out
    await settle(tester);
    expect(find.text(_signIn), findsOneWidget);
    expect(gear, findsNothing);
    expect(setup, findsNothing);

    merchantAddress.value = _me; // a returning user is not asked again
    await settle(tester);
    expect(destination, findsOneWidget);
    expect(fieldText(tester), isEmpty, reason: 'the old sale is gone');
    expect(find.text(_configure), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a switch drops a destination that was already validated',
      (tester) async {
    seed({_me: 'key-1', _other: 'key-2'});
    await open(tester);
    await submit(tester, 'alice@example.com');
    expect(destination, findsNothing, reason: 'past the first step');

    merchantAddress.value = _other;
    await settle(tester);

    expect(destination, findsOneWidget, reason: 'back to the first step');
    expect(fieldText(tester), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the done key of the keyboard continues', (tester) async {
    seed({_me: 'key-1'});
    await open(tester);

    await tester.enterText(destination, 'alice@example.com');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    expect(fake.validated, ['alice@example.com']);
    expect(destination, findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a slow read for the previous user does not take over',
      (tester) async {
    final slow = SlowAccounts()..holds[_me] = Completer();
    wapuAccounts = slow;
    await open(tester); // _me has a key, but the read is still pending
    expect(destination, findsNothing);
    expect(find.text(_configure), findsNothing, reason: 'nothing is known yet');

    merchantAddress.value = _other; // has no key
    await settle(tester);
    expect(find.text(_configure), findsOneWidget);

    slow.holds[_me]!.complete(const WapuCredentials(apiKey: 'key-1'));
    await settle(tester);

    expect(find.text(_configure), findsOneWidget,
        reason: "the new user does not get the previous user's key");
    expect(destination, findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an answer that comes after a POS switch is dropped',
      (tester) async {
    seed({_me: 'key-1', _other: 'key-2'});
    fake.hold = Completer<void>();
    await open(tester);
    await submit(tester, 'alice@example.com');
    expect(fake.validated, ['alice@example.com']);

    merchantAddress.value = _other;
    await settle(tester);
    expect(destination, findsOneWidget);
    expect(tester.widget<TextField>(destination).enabled, isTrue,
        reason: 'the new user is not left waiting for the old lookup');

    fake.hold!.complete();
    await settle(tester);

    expect(destination, findsOneWidget, reason: 'the new sale did not move');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed lookup says why and keeps the address', (tester) async {
    seed({_me: 'key-1'});
    await open(tester);

    fake.fail =
        LnurlException('La dirección no es una Lightning Address válida');
    await submit(tester, 'alice@example.com');
    expect(find.text('La dirección no es una Lightning Address válida'),
        findsOneWidget);
    expect(find.text(_unverified), findsNothing);
    expect(fieldText(tester), 'alice@example.com');

    fake.fail = StateError('boom');
    await tester.tap(next);
    await settle(tester);
    expect(find.text(_unverified), findsOneWidget);
    expect(find.text('La dirección no es una Lightning Address válida'),
        findsNothing);
    expect(find.textContaining('boom'), findsNothing,
        reason: 'only our own copy reaches the operator');

    fake.fail = null;
    await tester.tap(next);
    await settle(tester);
    expect(fake.validated, hasLength(3));
    expect(destination, findsNothing, reason: 'it resolves now');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the lookup shows progress and waits for its answer',
      (tester) async {
    seed({_me: 'key-1'});
    fake.hold = Completer<void>();
    await open(tester);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await submit(tester, 'alice@example.com');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.widget<FilledButton>(next).onPressed, isNull);
    expect(tester.widget<TextField>(destination).enabled, isFalse);

    await tester.tap(next); // ignored: the button is off
    await settle(tester);
    expect(fake.validated, hasLength(1));

    fake.hold!.complete();
    await settle(tester);
    expect(destination, findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Escanear QR puts the scanned text in the field', (tester) async {
    seed({_me: 'key-1'});
    await open(tester);

    Future<void> openScanner() async {
      await tester.tap(find.text('Escanear QR'));
      await settle(tester);
      expect(find.text('Escaneá la lightning address del cliente'),
          findsOneWidget);
    }

    await openScanner();
    await tester.tap(find.byIcon(Icons.close)); // the X: nothing was scanned
    await settle(tester);
    expect(find.byType(TokenScanPage), findsNothing);
    expect(fieldText(tester), isEmpty);

    await openScanner();
    camera.scans.add(BarcodeCapture(
        barcodes: [Barcode(rawValue: 'lightning:Bob@Example.com')]));
    await settle(tester);
    expect(find.byType(TokenScanPage), findsNothing);
    expect(fieldText(tester), 'lightning:Bob@Example.com',
        reason: 'the raw text: Continuar normalizes it');

    await tester.tap(next);
    await settle(tester);
    expect(fake.validated, ['bob@example.com']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a scan clears the message of the last try', (tester) async {
    seed({_me: 'key-1'});
    await open(tester);
    await submit(tester, 'hello');
    expect(find.text(_notAnAddress), findsOneWidget);

    await tester.tap(find.text('Escanear QR'));
    await settle(tester);
    camera.scans
        .add(BarcodeCapture(barcodes: [Barcode(rawValue: 'bob@example.com')]));
    await settle(tester);

    expect(fieldText(tester), 'bob@example.com');
    expect(find.text(_notAnAddress), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  group('after the config closes', () {
    testWidgets('a saved key brings the sale in', (tester) async {
      await open(tester);
      expect(find.text(_configure), findsOneWidget);

      await tester.tap(setup); // no PIN is set: straight in
      await settle(tester);
      expect(find.byType(WapuSettingsScreen), findsOneWidget);
      await tester.enterText(find.byKey(const Key('wapu-key')), 'new-key');
      await tester.tap(find.byKey(const Key('wapu-save')));
      await settle(tester);

      expect(find.byType(WapuSettingsScreen), findsNothing);
      expect(find.text(_configure), findsNothing);
      expect(destination, findsOneWidget);
      expect((await stored(tester, _me))?.apiKey, 'new-key');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a close with no result reloads the key all the same',
        (tester) async {
      await open(tester);
      await tester.tap(setup);
      await settle(tester);
      expect(find.byType(WapuSettingsScreen), findsOneWidget);

      // A partial save leaves the config open, and the back pops null.
      await tester.runAsync(() =>
          wapuAccounts.save(_me, const WapuCredentials(apiKey: 'late-key')));
      await tester.tap(find.byIcon(Icons.arrow_back));
      await settle(tester);

      expect(find.byType(WapuSettingsScreen), findsNothing);
      expect(destination, findsOneWidget);
      expect(find.text(_configure), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a forgotten key brings the setup back', (tester) async {
      seed({_me: 'key-1'});
      await open(tester);
      expect(destination, findsOneWidget);

      await tester.tap(gear);
      await settle(tester);
      await tester.tap(find.byKey(const Key('wapu-forget')));
      await settle(tester);

      expect(find.byType(WapuSettingsScreen), findsNothing);
      expect(find.text(_configure), findsOneWidget);
      expect(destination, findsNothing);
      expect(await stored(tester, _me), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('the screen is translated', (tester) async {
    seed({_me: 'key-1'});
    await open(tester, english: true);

    expect(find.text("Customer's Lightning address"), findsOneWidget);
    expect(find.text('name@domain.com'), findsOneWidget);
    expect(find.text('Scan QR'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);

    for (final (text, copy) in [
      (
        _invoice,
        'That is an invoice. Ask the customer for their Lightning address'
      ),
      (
        _lnurl,
        'That is an LNURL. Ask the customer for their Lightning address'
      ),
      ('hello', 'The Lightning address is not valid'),
    ]) {
      await submit(tester, text);
      expect(find.text(copy), findsOneWidget, reason: text);
    }
    fake.fail = StateError('boom');
    await submit(tester, 'alice@example.com');
    expect(find.text('The Lightning address could not be verified'),
        findsOneWidget);

    await tester.tap(find.text('Scan QR'));
    await settle(tester);
    expect(find.text("Scan the customer's Lightning address"), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await settle(tester);

    merchantAddress.value = _other;
    await settle(tester);
    expect(find.text('Set up your Wapu API key'), findsOneWidget);
    expect(find.text('Set up'), findsOneWidget);

    merchantAddress.value = '';
    await settle(tester);
    expect(find.text('Sign in with the merchant address to use Wapu'),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  group('amount', () {
    setUp(() {
      seed({_me: 'key-1'});
      net.routes[_quoteRoute] = quoteReply();
    });

    /// Opens the sale and gets past the first step.
    Future<void> toAmount(WidgetTester tester,
        {String address = 'alice@example.com', bool english = false}) async {
      await open(tester, english: english);
      await submit(tester, address);
      expect(amount, findsOneWidget, reason: 'the address was taken');
    }

    VoidCallback? confirmAction(WidgetTester tester) =>
        tester.widget<FilledButton>(confirm).onPressed;

    testWidgets('quotes in pesos after the debounce', (tester) async {
      await toAmount(tester);
      expect(find.text('\$ 0'), findsOneWidget, reason: 'pesos by default');
      expect(confirmAction(tester), isNull, reason: 'no amount, no order');

      await typeDigits(tester, '15000');
      expect(find.text('\$ 15.000'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget,
          reason: 'the price is on its way');

      await tester.pump(const Duration(milliseconds: 400));
      expect(net.calls, isEmpty, reason: 'the operator may still be typing');

      await tester.pump(const Duration(milliseconds: 200));
      expect(net.calls, [_quoteRoute]);
      expect(net.queries.single, containsPair('amount_ars_cents', '1500000'));
      expect(net.queries.single, isNot(contains('amount_out')));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('El cliente recibe'), findsOneWidget);
      expect(line('El cliente recibe', '12.500 sats'), findsOneWidget);
      expect(line('Tipo de cambio', '\$ 120.000.000 por BTC'), findsOneWidget);
      expect(line('Comisión incluida', '1,50%'), findsOneWidget);
      expect(line('Fee de red estimado', '21 sats'), findsOneWidget);
      expect(confirmAction(tester), isNotNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('sats mode quotes amount_out', (tester) async {
      net.routes[_quoteRoute] = quoteReply(ars: 1000000, out: 50000);
      await toAmount(tester);

      await tester.tap(inSats);
      await tester.pump();
      expect(find.text('0 sats'), findsOneWidget);

      await typeDigits(tester, '50000');
      expect(find.text('50.000 sats'), findsOneWidget,
          reason: 'what was typed');
      await tester.pump(const Duration(milliseconds: 600));

      expect(net.calls, [_quoteRoute]);
      expect(net.queries.single, containsPair('amount_out', '50000'));
      expect(net.queries.single, isNot(contains('amount_ars_cents')));
      expect(line('El cliente recibe', '50.000 sats'), findsOneWidget);
      expect(line('Tipo de cambio', '\$ 20.000.000 por BTC'), findsOneWidget);
      expect(confirmAction(tester), isNotNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('sats mode shows the ARS the customer pays', (tester) async {
      net.routes[_quoteRoute] = quoteReply(ars: 22400, out: 50000);
      await toAmount(tester);

      await tester.tap(inSats);
      await tester.pump();
      await typeDigits(tester, '50000');
      await tester.pump(const Duration(milliseconds: 600));
      expect(line('El cliente paga', '\$ 224,00'), findsOneWidget);
      expect(line('El cliente recibe', '50.000 sats'), findsOneWidget);
      expect(tester.getTopLeft(find.text('El cliente paga')).dy,
          lessThan(tester.getTopLeft(find.text('El cliente recibe')).dy),
          reason: 'the figure the operator must see comes first');

      // To the centavo, with the thousands grouped by dots.
      net.routes[_quoteRoute] = quoteReply(ars: 123456705, out: 500000);
      await typeDigits(tester, '0');
      await tester.pump(const Duration(milliseconds: 600));
      expect(line('El cliente paga', '\$ 1.234.567,05'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('pesos mode has no El cliente paga line', (tester) async {
      net.routes[_quoteRoute] = quoteReply(ars: 22400, out: 50000);
      await toAmount(tester);

      await typeDigits(tester, '224');
      await tester.pump(const Duration(milliseconds: 600));
      expect(line('El cliente recibe', '50.000 sats'), findsOneWidget);
      expect(find.text('El cliente paga'), findsNothing,
          reason: 'what was typed is what the customer pays');
      expect(find.textContaining('224,00'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    group('stale quotes are ignored', () {
      testWidgets('two edits less than 500 ms apart send one request',
          (tester) async {
        await toAmount(tester);
        await typeDigits(tester, '1');
        await tester.pump(const Duration(milliseconds: 300));
        await typeDigits(tester, '2');
        await tester.pump(const Duration(milliseconds: 300));
        expect(net.calls, isEmpty,
            reason: '600 ms after the first edit, 300 after the second');

        await tester.pump(const Duration(milliseconds: 200));
        expect(net.calls, [_quoteRoute]);
        expect(net.queries.single, containsPair('amount_ars_cents', '1200'));
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets('a reply that lands after a newer amount is dropped',
          (tester) async {
        final first = Completer<void>();
        net.routes[_quoteRoute] = quoteReply(ars: 100, out: 1111);
        net.hold = (_) => first.future;
        await toAmount(tester);

        await typeDigits(tester, '1');
        await tester.pump(const Duration(milliseconds: 500));
        expect(net.queries, hasLength(1), reason: 'the first price is held');

        net.routes[_quoteRoute] = quoteReply(ars: 1200, out: 2222);
        net.hold = null;
        await typeDigits(tester, '2');
        await tester.pump(const Duration(milliseconds: 500));
        expect(net.queries, hasLength(2));
        expect(net.queries.last, containsPair('amount_ars_cents', '1200'));
        expect(line('El cliente recibe', '2.222 sats'), findsOneWidget,
            reason: 'the second price came back first');

        first.complete(); // the first price lands last
        await settle(tester);
        expect(line('El cliente recibe', '2.222 sats'), findsOneWidget);
        expect(find.text('1.111 sats'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      });
    });

    testWidgets('below the minimum disables confirm', (tester) async {
      net.routes[_quoteRoute] = quoteReply(ars: 99900, min: 100000);
      await toAmount(tester);

      await typeDigits(tester, '999');
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('El mínimo es \$ 1.000'), findsOneWidget);
      expect(find.text('El cliente recibe'), findsOneWidget,
          reason: 'the price is still the price');
      expect(tester.getTopLeft(find.text('El mínimo es \$ 1.000')).dy,
          lessThan(tester.getTopLeft(find.text('El cliente recibe')).dy),
          reason: 'why Confirmar is off comes before the lines that scroll');
      expect(confirmAction(tester), isNull);

      // The minimum itself is enough.
      net.routes[_quoteRoute] = quoteReply(ars: 100000, min: 100000);
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byIcon(Icons.backspace_outlined));
        await tester.pump();
      }
      await typeDigits(tester, '1000');
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.textContaining('El mínimo es'), findsNothing);
      expect(confirmAction(tester), isNotNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no liquidity disables confirm', (tester) async {
      net.routes[_quoteRoute] = quoteReply(liquidity: false);
      await toAmount(tester);

      await typeDigits(tester, '15000');
      await tester.pump(const Duration(milliseconds: 600));
      expect(
          find.text('No hay liquidez disponible ahora. Probá en unos minutos.'),
          findsOneWidget);
      expect(find.textContaining('El mínimo es'), findsNothing);
      expect(confirmAction(tester), isNull);

      net.routes[_quoteRoute] = quoteReply();
      await typeDigits(tester, '0');
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.textContaining('No hay liquidez'), findsNothing);
      expect(confirmAction(tester), isNotNull, reason: 'liquidity is back');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a quote error is shown and confirm stays disabled',
        (tester) async {
      net.routes[_quoteRoute] = (422, {'error': 'amount out of range'});
      await toAmount(tester);

      await typeDigits(tester, '15000');
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('El monto está fuera de los límites'), findsOneWidget);
      expect(find.text('amount out of range'), findsOneWidget,
          reason: "the backend's own words, small, under the copy");
      expect(find.text('El cliente recibe'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(confirmAction(tester), isNull);

      // The next edit asks again, and the error was the old amount's.
      net.routes[_quoteRoute] = quoteReply();
      await typeDigits(tester, '0');
      expect(find.text('El monto está fuera de los límites'), findsNothing);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('El cliente recibe'), findsOneWidget);
      expect(confirmAction(tester), isNotNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failure of our own shows the generic copy', (tester) async {
      wapuApiFor = (_, __) => BrokenApi();
      await toAmount(tester);

      await typeDigits(tester, '15000');
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('No se pudo completar la operación'), findsOneWidget);
      expect(find.textContaining('boom'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'it does not wait for ever');
      expect(confirmAction(tester), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('switching the unit clears the amount and its price',
        (tester) async {
      await toAmount(tester);
      await typeDigits(tester, '15000');
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('El cliente recibe'), findsOneWidget);

      await tester.tap(inArs); // the unit it is in already: nothing to clear
      await tester.pump();
      expect(find.text('\$ 15.000'), findsOneWidget);
      expect(find.text('El cliente recibe'), findsOneWidget);

      await tester.tap(inSats);
      await tester.pump();
      expect(find.text('0 sats'), findsOneWidget);
      expect(find.text('El cliente recibe'), findsNothing);
      expect(confirmAction(tester), isNull);

      await settle(tester);
      expect(net.calls, hasLength(1), reason: 'there is nothing to price');

      await tester.tap(inArs);
      await tester.pump();
      expect(find.text('\$ 0'), findsOneWidget);
      await settle(tester);
      expect(net.calls, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the pad takes 12 digits, no leading zeros, and backspaces',
        (tester) async {
      await toAmount(tester);
      await tester.tap(find.text('0'));
      await tester.tap(find.text('00'));
      await tester.pump();
      expect(find.text('\$ 0'), findsOneWidget, reason: 'zeros are no amount');

      await typeDigits(tester, '12345678901');
      expect(find.text('\$ 12.345.678.901'), findsOneWidget);
      await tester.tap(find.text('00')); // two more would be 13
      await tester.pump();
      expect(find.text('\$ 12.345.678.901'), findsOneWidget);

      await typeDigits(tester, '2'); // the 12th
      expect(find.text('\$ 123.456.789.012'), findsOneWidget);
      await typeDigits(tester, '3'); // the 13th
      expect(find.text('\$ 123.456.789.012'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.backspace_outlined));
      await tester.pump();
      expect(find.text('\$ 12.345.678.901'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the header shows the address, and its pencil goes back to it',
        (tester) async {
      await toAmount(tester, address: '  LIGHTNING:Alice@Example.COM ');
      expect(find.text('alice@example.com'), findsOneWidget,
          reason: 'the normalized address: where the sats go');
      await typeDigits(tester, '15000');
      await tester.pump(const Duration(milliseconds: 600));
      expect(line('El cliente recibe', '12.500 sats'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pump();
      expect(destination, findsOneWidget);
      expect(amount, findsNothing);
      expect(fieldText(tester), '  LIGHTNING:Alice@Example.COM ',
          reason: 'what was typed stays, to be fixed');

      await submit(tester, 'Bob@Example.com');
      expect(fake.validated, ['alice@example.com', 'bob@example.com']);
      expect(find.text('bob@example.com'), findsOneWidget);
      expect(find.text('alice@example.com'), findsNothing);
      expect(find.text('\$ 15.000'), findsOneWidget,
          reason: 'the amount does not depend on the address');
      expect(line('El cliente recibe', '12.500 sats'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a POS switch drops the amount and the price on its way',
        (tester) async {
      seed({_me: 'key-1', _other: 'key-2'});
      final held = Completer<void>();
      net.hold = (_) => held.future;
      await toAmount(tester);
      await tester.tap(inSats);
      await tester.pump();
      await typeDigits(tester, '15000');
      await tester.pump(const Duration(milliseconds: 500));
      expect(net.queries, hasLength(1), reason: 'the price is held');

      merchantAddress.value = _other;
      await settle(tester);
      expect(destination, findsOneWidget, reason: 'the other user starts over');

      held.complete(); // the first user's price lands
      await settle(tester);
      net.hold = null;
      await submit(tester, 'bob@example.com');
      expect(find.text('\$ 0'), findsOneWidget, reason: 'a new sale, in pesos');
      expect(find.text('El cliente recibe'), findsNothing);
      expect(net.queries, hasLength(1), reason: 'nothing asked again');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a base URL changed in the config starts the sale over',
        (tester) async {
      await toAmount(tester);
      await typeDigits(tester, '15000');
      await tester.pump(const Duration(milliseconds: 600));
      expect(line('El cliente recibe', '12.500 sats'), findsOneWidget);
      expect(confirmAction(tester), isNotNull);
      expect(net.hosts.last, 'be-prod.wapu.app');

      await tester.tap(gear); // no PIN is set: straight in
      await settle(tester);
      await tester.tap(find.byType(ExpansionTile)); // Avanzado
      await settle(tester);
      await tester.enterText(
          find.byKey(const Key('wapu-url')), 'be-stage.wapu.app');
      await tester.tap(find.byKey(const Key('wapu-save'))); // keeps the key
      await settle(tester);

      expect(find.byType(WapuSettingsScreen), findsNothing);
      expect(destination, findsOneWidget,
          reason: 'a sale on the old backend does not go on on the new one');
      expect(amount, findsNothing);
      expect(fieldText(tester), isEmpty);

      await submit(tester, 'alice@example.com');
      expect(find.text('\$ 0'), findsOneWidget);
      expect(find.text('El cliente recibe'), findsNothing,
          reason: "the old backend's price is not the new one's");
      expect(confirmAction(tester), isNull);

      await typeDigits(tester, '15000');
      await tester.pump(const Duration(milliseconds: 600));
      expect(line('El cliente recibe', '12.500 sats'), findsOneWidget);
      expect(confirmAction(tester), isNotNull);
      expect(net.hosts.last, 'be-stage.wapu.app',
          reason: 'the new price is asked of the new backend');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a config closed with the same account keeps the amount',
        (tester) async {
      await toAmount(tester);
      await typeDigits(tester, '15000');
      await tester.pump(const Duration(milliseconds: 600));

      await tester.tap(gear);
      await settle(tester);
      expect(find.byType(WapuSettingsScreen), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_back)); // nothing changed
      await settle(tester);

      expect(find.byType(WapuSettingsScreen), findsNothing);
      expect(find.text('\$ 15.000'), findsOneWidget);
      expect(line('El cliente recibe', '12.500 sats'), findsOneWidget);
      expect(confirmAction(tester), isNotNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the amount step is translated', (tester) async {
      net.routes[_quoteRoute] =
          quoteReply(ars: 50000, min: 2000000, liquidity: false);
      await toAmount(tester, english: true);
      expect(find.text('Confirm'), findsOneWidget);
      expect(find.byTooltip('CHANGE ADDRESS'), findsOneWidget);

      await typeDigits(tester, '500');
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('The customer receives'), findsOneWidget);
      expect(line('Exchange rate', '\$ 4.000.000 per BTC'), findsOneWidget);
      expect(find.text('Fee included'), findsOneWidget);
      expect(find.text('Estimated network fee'), findsOneWidget);
      expect(find.text('The minimum is \$ 20.000'), findsOneWidget);
      expect(
          find.text('No liquidity available right now. Try again in a few '
              'minutes.'),
          findsOneWidget);

      net.routes[_quoteRoute] = (422, {'error': 'out'});
      await typeDigits(tester, '0');
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('The amount is out of range'), findsOneWidget);

      net.routes[_quoteRoute] = quoteReply(ars: 22400, out: 50000);
      await tester.tap(inSats);
      await tester.pump();
      await typeDigits(tester, '5');
      await tester.pump(const Duration(milliseconds: 600));
      expect(line('The customer pays', '\$ 224,00'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('status', () {
    /// What the till asked the speaker to play, by name.
    final played = <String>[];

    setUp(() async {
      seed({_me: 'key-1'});
      net.routes[_quoteRoute] = quoteReply();
      net.routes[_createRoute] = createdReply();
      net.routes[_fundRoute] = orderReply(code: 201);
      net.routes[_detailRoute] = orderReply();
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

    /// How many times the till called [route].
    int calls(String route) => net.calls.where((c) => c == route).length;

    /// How many times the paid cue played, not counting the buttons' clicks.
    int paid() => played.where((n) => n == 'arpeggio').length;

    VoidCallback? confirmAction(WidgetTester tester) =>
        tester.widget<FilledButton>(confirm).onPressed;

    /// Holds the requests to [path] until the returned completer completes.
    Completer<void> holdOn(String method, String path) {
      final held = Completer<void>();
      net.hold = (o) => o.method == method && o.uri.path == path
          ? held.future
          : Future.value();
      return held;
    }

    /// Opens the sale and gets past the first step.
    Future<void> toAmount(WidgetTester tester, {bool english = false}) async {
      await open(tester, english: english);
      await submit(tester, 'alice@example.com');
      expect(amount, findsOneWidget, reason: 'the address was taken');
    }

    /// Types $ 15.000 and waits for its price.
    Future<void> price(WidgetTester tester) async {
      await typeDigits(tester, '15000');
      await tester.pump(const Duration(milliseconds: 600));
    }

    /// Types $ 15.000, waits for its price and taps Confirmar.
    Future<void> priceAndConfirm(WidgetTester tester) async {
      await price(tester);
      await tester.tap(confirm);
      await settle(tester);
    }

    /// The sale, up to an order that waits for the transfer.
    Future<void> toWaiting(WidgetTester tester, {bool english = false}) async {
      await toAmount(tester, english: english);
      await priceAndConfirm(tester);
      expect(find.text(_alias), findsOneWidget, reason: 'the order is funded');
    }

    /// Taps the Nueva venta of the dialog that asks first.
    Future<void> confirmDialog(WidgetTester tester) async {
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Nueva venta')));
      await settle(tester);
    }

    const unknownOutcome = 'No sabemos si la orden se creó. '
        'Revisá el Historial antes de reintentar.';

    testWidgets('confirm creates, funds and shows the funded amount',
        (tester) async {
      await toAmount(tester);
      await price(tester);
      expect(line('El cliente recibe', '12.500 sats'), findsOneWidget);

      await tester.tap(confirm);
      await settle(tester);

      expect(net.calls, [_quoteRoute, _createRoute, _fundRoute]);
      expect(net.bodies[1], {
        'type': 'crypto_purchase',
        'payout_currency': 'SAT',
        'payout_network': 'LIGHTNING',
        'payout_address': 'alice@example.com',
        'amount_ars_cents': 1500000,
      });
      expect(amount, findsNothing);
      expect(find.text('Esperando la transferencia'), findsOneWidget);
      expect(find.text(_alias), findsOneWidget);
      expect(find.text(_cvu), findsOneWidget);
      expect(find.text(r'$ 15.000,37'), findsOneWidget,
          reason: 'what funding says the customer pays');
      expect(find.text(r'$ 15.000,00'), findsNothing,
          reason: "not the quote's amount");
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('sats mode creates the order for the sats typed',
        (tester) async {
      net.routes[_quoteRoute] = quoteReply(ars: 1000000, out: 50000);
      await toAmount(tester);
      await tester.tap(inSats);
      await tester.pump();
      await typeDigits(tester, '50000');
      await tester.pump(const Duration(milliseconds: 600));

      await tester.tap(confirm);
      await settle(tester);

      expect(net.bodies[1], containsPair('amount_out', 50000));
      expect(net.bodies[1], isNot(contains('amount_ars_cents')));
      expect(find.text(_alias), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a create timeout says to check the history and does not retry',
        (tester) async {
      net.failures[_createRoute] = DioException(
          requestOptions: RequestOptions(),
          type: DioExceptionType.receiveTimeout);
      await toAmount(tester);
      await priceAndConfirm(tester);

      expect(find.text(unknownOutcome), findsOneWidget);
      expect(find.byKey(const Key('wapu-error-detail')), findsNothing,
          reason: "'timeout' is the API's word, and the copy says it");
      expect(amount, findsOneWidget, reason: 'the sale stays on the amount');
      expect(confirmAction(tester), isNotNull,
          reason: 'the operator decides when to try again');

      await tester.pump(const Duration(seconds: 60));
      expect(calls(_createRoute), 1, reason: 'never retried on its own');
      expect(calls(_fundRoute), 0);

      await typeDigits(tester, '0'); // the error was the old amount's
      expect(find.text(unknownOutcome), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no connection on create leaves the outcome unknown too',
        (tester) async {
      net.failures[_createRoute] = DioException(
          requestOptions: RequestOptions(),
          type: DioExceptionType.connectionError);
      await toAmount(tester);
      await priceAndConfirm(tester);

      expect(find.text(unknownOutcome), findsOneWidget);
      expect(amount, findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failure of our own on create leaves the outcome unknown',
        (tester) async {
      wapuApiFor = (_, __) => BrokenCreateApi(Dio()..httpClientAdapter = net);
      await toAmount(tester);
      await priceAndConfirm(tester);

      expect(find.text(unknownOutcome), findsOneWidget);
      expect(find.textContaining('boom'), findsNothing);
      expect(amount, findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('only a create that surely made no order may be tried again',
        (tester) async {
      await toAmount(tester);
      await price(tester);

      for (final (code, said, copy, unknown) in [
        (500, 'internal error', unknownOutcome, true),
        (
          400,
          'lightning address rejected: no such user',
          'La lightning address o el monto no son válidos',
          false,
        ),
        (
          503,
          'payout provider unavailable',
          'El servicio no está disponible. Probá más tarde.',
          false,
        ),
        (
          429,
          'too many open purchase orders',
          'Hay demasiadas órdenes abiertas. Esperá a que venzan.',
          false,
        ),
      ]) {
        net.routes[_createRoute] = (code, {'error': said});
        await tester.tap(confirm);
        await settle(tester);

        expect(find.text(copy), findsOneWidget, reason: '$code');
        expect(find.text(said), findsOneWidget,
            reason: "the backend's own words, under the copy");
        expect(
            find.text(unknownOutcome), unknown ? findsOneWidget : findsNothing,
            reason: '$code');
        expect(amount, findsOneWidget);
        expect(confirmAction(tester), isNotNull);
      }
      expect(calls(_createRoute), 4);

      net.routes[_createRoute] = createdReply();
      await tester.tap(confirm);
      await settle(tester);
      expect(find.text(_alias), findsOneWidget);
      expect(find.textContaining('Hay demasiadas'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('going back to the address drops the error of the create',
        (tester) async {
      net.routes[_createRoute] =
          (429, {'error': 'too many open purchase orders'});
      await toAmount(tester);
      await priceAndConfirm(tester);
      expect(find.textContaining('Hay demasiadas'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pump();
      await submit(tester, 'bob@example.com');

      expect(amount, findsOneWidget);
      expect(find.textContaining('Hay demasiadas'), findsNothing,
          reason: 'it was about the old address');
      expect(line('El cliente recibe', '12.500 sats'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a second tap while the order is created sends no second one',
        (tester) async {
      final held = holdOn('POST', _tentatives);
      await toAmount(tester);
      await price(tester);

      await tester.tap(confirm);
      await tester.tap(confirm); // before a rebuild: the screen guards itself
      await tester.pump();
      expect(confirmAction(tester), isNull, reason: 'it waits for the order');
      expect(
          find.descendant(
              of: confirm, matching: find.byType(CircularProgressIndicator)),
          findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);

      await tester.tap(confirm, warnIfMissed: false);
      await settle(tester);
      expect(calls(_createRoute), 1);

      held.complete();
      await settle(tester);
      expect(calls(_createRoute), 1);
      expect(calls(_fundRoute), 1);
      expect(find.text(_alias), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    /// What the three app bar buttons would run if they were pressed now.
    List<VoidCallback> pressesOfAppBar(WidgetTester tester) => [
          for (final button in [newSale, history, gear])
            tester.widget<IconButton>(button).onPressed!,
        ];

    /// Taps Nueva venta, Historial and the gear, and runs [stale], the presses
    /// that were on their way before the buttons went off. None may do a thing.
    Future<void> expectAppBarWaits(
        WidgetTester tester, List<VoidCallback> stale) async {
      for (final button in [newSale, history, gear]) {
        expect(tester.widget<IconButton>(button).onPressed, isNull);
        await tester.tap(button, warnIfMissed: false);
      }
      for (final press in stale) {
        press();
      }
      await settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(WapuSettingsScreen), findsNothing);
    }

    testWidgets('the app bar waits while an order is created', (tester) async {
      final held = holdOn('POST', _tentatives);
      await toAmount(tester);
      await price(tester);
      final stale = pressesOfAppBar(tester);

      await tester.tap(confirm);
      await settle(tester);
      expect(calls(_createRoute), 1, reason: 'the create is out');
      await expectAppBarWaits(tester, stale);
      expect(amount, findsOneWidget, reason: 'the sale is where it was');
      expect(find.text(r'$ 15.000'), findsOneWidget);

      held.complete();
      await settle(tester);
      expect(find.text(_alias), findsOneWidget, reason: 'the order shows');
      expect(calls(_createRoute), 1);
      expect(calls(_fundRoute), 1);
      for (final button in [newSale, history, gear]) {
        expect(tester.widget<IconButton>(button).onPressed, isNotNull);
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the app bar waits while the funding is asked for',
        (tester) async {
      final held = holdOn('POST', '$_tentatives/t1/funding');
      await toAmount(tester);
      await price(tester);
      final stale = pressesOfAppBar(tester);

      await tester.tap(confirm);
      await settle(tester);
      expect(find.text('Orden creada'), findsOneWidget);
      await expectAppBarWaits(tester, stale);
      expect(find.text('Orden creada'), findsOneWidget);

      held.complete();
      await settle(tester);
      expect(find.text(_alias), findsOneWidget);
      for (final button in [newSale, history, gear]) {
        expect(tester.widget<IconButton>(button).onPressed, isNotNull);
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the amount cannot be retyped under a pending create',
        (tester) async {
      net.failures[_createRoute] = DioException(
          requestOptions: RequestOptions(),
          type: DioExceptionType.receiveTimeout);
      final held = holdOn('POST', _tentatives);
      await toAmount(tester);
      await price(tester);
      await tester.tap(confirm);
      await settle(tester);
      expect(calls(_createRoute), 1, reason: 'the create is out');
      expect(find.text(r'$ 15.000'), findsOneWidget);

      await tester.tap(find.text('7'));
      await tester.tap(find.byIcon(Icons.backspace_outlined));
      await tester.tap(inSats);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text(r'$ 15.000'), findsOneWidget,
          reason: 'the amount is the one being created');
      expect(find.text('0 sats'), findsNothing, reason: 'still in pesos');
      expect(calls(_quoteRoute), 1, reason: 'no price was asked for');

      held.complete(); // the create fails: the sale is where it was
      await settle(tester);
      expect(find.text(r'$ 15.000'), findsOneWidget);
      expect(confirmAction(tester), isNotNull, reason: 'its price still stands');
      expect(calls(_quoteRoute), 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Confirmar waits while the key is read again after the config',
        (tester) async {
      final slow = SlowAccounts();
      wapuAccounts = slow;
      await toAmount(tester);
      await price(tester);
      expect(confirmAction(tester), isNotNull);

      await tester.tap(gear); // no PIN is set: straight in
      await settle(tester);
      slow.holds[_me] = Completer(); // the read after the config closes
      await tester.tap(find.byIcon(Icons.arrow_back));
      await settle(tester);

      expect(find.byType(WapuSettingsScreen), findsNothing);
      expect(confirmAction(tester), isNull,
          reason: 'the key on screen may not be the one the config left');
      await tester.tap(confirm, warnIfMissed: false);
      await settle(tester);
      expect(calls(_createRoute), 0, reason: 'nothing was created');

      slow.holds[_me]!.complete(const WapuCredentials(apiKey: 'key-1'));
      await settle(tester);
      expect(confirmAction(tester), isNotNull,
          reason: 'the same account: its price stays');
      expect(line('El cliente recibe', '12.500 sats'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('funding failure offers a retry', (tester) async {
      net.routes[_fundRoute] = (503, {'error': 'payout provider unavailable'});
      await toAmount(tester);
      await priceAndConfirm(tester);

      expect(find.text('Orden creada'), findsOneWidget);
      expect(fundButton, findsOneWidget);
      expect(find.text('El servicio no está disponible. Probá más tarde.'),
          findsOneWidget);
      expect(find.text(_alias), findsNothing);
      expect(calls(_createRoute), 1);

      final held = holdOn('POST', '$_tentatives/t1/funding');
      net.routes[_fundRoute] = orderReply(code: 201);
      await tester.tap(fundButton);
      await tester.pump();
      expect(tester.widget<FilledButton>(fundButton).onPressed, isNull,
          reason: 'it waits for the details');
      expect(find.text('El servicio no está disponible. Probá más tarde.'),
          findsNothing,
          reason: 'it is being tried again');
      held.complete();
      await settle(tester);

      expect(calls(_fundRoute), 2);
      expect(calls(_createRoute), 1, reason: 'the order is not created again');
      expect(fundButton, findsNothing);
      expect(find.text(_alias), findsOneWidget);
      expect(find.text(r'$ 15.000,37'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a funding that gets no answer can be asked for again',
        (tester) async {
      net.failures[_fundRoute] = DioException(
          requestOptions: RequestOptions(),
          type: DioExceptionType.receiveTimeout);
      await toAmount(tester);
      await priceAndConfirm(tester);

      expect(find.text('El servidor no respondió. Probá de nuevo.'),
          findsOneWidget);
      expect(fundButton, findsOneWidget);

      net.failures.clear();
      await tester.tap(fundButton);
      await settle(tester);
      expect(find.text(_alias), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('polling advances to done and plays once', (tester) async {
      await toWaiting(tester);
      expect(calls(_detailRoute), 0, reason: 'the order was just funded');

      await tester.pump(const Duration(seconds: 10));
      expect(calls(_detailRoute), 1);
      expect(find.text('Esperando la transferencia'), findsOneWidget);

      net.routes[_detailRoute] =
          orderReply(status: 'EXECUTED', payout: 'sending', bank: false);
      await tester.pump(const Duration(seconds: 10));
      expect(calls(_detailRoute), 2);
      expect(find.text('Pago recibido. Enviando los sats…'), findsOneWidget);
      expect(find.text(_alias), findsNothing,
          reason: 'a paid order has no bank details to show');
      expect(paid(), 0);

      net.routes[_detailRoute] = completedReply();
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(calls(_detailRoute), 3);
      expect(find.text('¡Listo! El cliente recibió 12.500 sats'),
          findsOneWidget);
      expect(find.text(_hash), findsOneWidget);
      expect(paid(), 1);

      await tester.pump(const Duration(seconds: 30));
      expect(calls(_detailRoute), 3, reason: 'polling stopped');
      expect(paid(), 1, reason: 'the cue plays once');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a completed order that is still watched plays the cue once',
        (tester) async {
      await toWaiting(tester);
      net.routes[_detailRoute] = orderReply(
          status: 'COMPLETED', payout: 'completed', bank: false, hash: _hash);

      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();

      expect(calls(_detailRoute), 2, reason: 'still watched, so still read');
      expect(find.textContaining('¡Listo!'), findsOneWidget);
      expect(paid(), 1, reason: 'only the transition into COMPLETED plays');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an order that went to the balance stops the polling quietly',
        (tester) async {
      await toWaiting(tester);
      net.routes[_detailRoute] = orderReply(
          status: 'SETTLED_TO_BALANCE',
          payout: 'settled_to_balance',
          watch: false,
          bank: false);
      await tester.pump(const Duration(seconds: 10));

      expect(find.text('No se pudieron enviar los sats'), findsOneWidget);
      expect(paid(), 0, reason: 'the customer did not get the sats');
      await tester.pump(const Duration(seconds: 30));
      expect(calls(_detailRoute), 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a poll that is still out is not overlapped by the next tick',
        (tester) async {
      await toWaiting(tester);
      final held = holdOn('GET', '$_tentatives/t1');

      await tester.pump(const Duration(seconds: 10));
      expect(calls(_detailRoute), 1);
      await tester.pump(const Duration(seconds: 10));
      expect(calls(_detailRoute), 1,
          reason: 'the read of the last tick is still out');

      held.complete();
      await settle(tester);
      await tester.pump(const Duration(seconds: 10));
      expect(calls(_detailRoute), 2);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the countdown moves while it waits for the transfer',
        (tester) async {
      await toWaiting(tester);
      String countdown() =>
          tester.widget<Text>(find.textContaining('Vence en')).data!;
      final before = countdown();

      // The countdown reads the device's clock, which a test cannot move: let a
      // real second go by, then the tick that repaints it.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1100)));
      expect(countdown(), before, reason: 'nothing repaints it by itself');
      await tester.pump(const Duration(seconds: 1));
      expect(countdown(), isNot(before));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a stale poll does not resurrect the old order',
        (tester) async {
      await toWaiting(tester);
      final held = holdOn('GET', '$_tentatives/t1');
      await tester.pump(const Duration(seconds: 10));
      expect(calls(_detailRoute), 1, reason: 'a read is on its way');

      await tester.tap(newSale);
      await settle(tester);
      await confirmDialog(tester);
      expect(destination, findsOneWidget);

      held.complete(); // the old order's answer lands in the new sale
      await settle(tester);

      expect(destination, findsOneWidget, reason: 'the new sale did not move');
      expect(find.text(_alias), findsNothing);
      await tester.pump(const Duration(seconds: 30));
      expect(calls(_detailRoute), 1, reason: 'nothing follows the old order');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("a stale poll does not overwrite the next sale's order",
        (tester) async {
      await toWaiting(tester);
      final held = holdOn('GET', '$_tentatives/t1');
      await tester.pump(const Duration(seconds: 10));

      await tester.tap(newSale);
      await settle(tester);
      await confirmDialog(tester);

      net.routes[_createRoute] = createdReply(id: 't2');
      net.routes['POST $_tentatives/t2/funding'] =
          orderReply(id: 't2', alias: 'otro.alias', code: 201);
      net.routes['GET $_tentatives/t2'] =
          orderReply(id: 't2', alias: 'otro.alias');
      await submit(tester, 'bob@example.com');
      await priceAndConfirm(tester);
      expect(find.text('otro.alias'), findsOneWidget);

      held.complete(); // t1's answer, with t1's bank details
      await settle(tester);

      expect(find.text('otro.alias'), findsOneWidget);
      expect(find.text(_alias), findsNothing);

      // And the new order is followed: the old read did not leave it waiting.
      await tester.pump(const Duration(seconds: 10));
      expect(calls('GET $_tentatives/t2'), 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Nueva venta stops the clocks of the old order',
        (tester) async {
      net.routes['POST $_tentatives/t2/funding'] =
          orderReply(id: 't2', alias: 'otro.alias', code: 201);
      await toWaiting(tester); // t1's clock reads it every 10 s
      await tester.pump(const Duration(seconds: 3));
      await tester.tap(newSale);
      await settle(tester);
      await confirmDialog(tester);

      net.routes[_createRoute] = createdReply(id: 't2');
      await submit(tester, 'bob@example.com');
      await priceAndConfirm(tester);
      expect(find.text('otro.alias'), findsOneWidget);

      // t1's clock would tick inside these 8 s; t2's own is a full 10 s away.
      await tester.pump(const Duration(seconds: 8));
      expect(calls('GET $_tentatives/t2'), 0);
      expect(calls(_detailRoute), 0);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a create that lands after the till changed hands is dropped',
        (tester) async {
      seed({_me: 'key-1', _other: 'key-2'});
      final held = holdOn('POST', _tentatives);
      await toAmount(tester);
      await price(tester);
      await tester.tap(confirm);
      await settle(tester);
      expect(calls(_createRoute), 1);

      merchantAddress.value = _other; // the sale of the old user is let go
      await settle(tester);
      expect(destination, findsOneWidget);

      held.complete();
      await settle(tester);

      expect(destination, findsOneWidget);
      expect(find.text('Orden creada'), findsNothing);
      expect(calls(_fundRoute), 0, reason: 'the abandoned order is not funded');

      // The next sale is not left waiting for the create that was let go.
      await submit(tester, 'bob@example.com');
      await priceAndConfirm(tester);
      expect(find.text(_alias), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a funding that lands after the till changed hands is dropped',
        (tester) async {
      seed({_me: 'key-1', _other: 'key-2'});
      final held = holdOn('POST', '$_tentatives/t1/funding');
      await toAmount(tester);
      await priceAndConfirm(tester);
      expect(find.text('Orden creada'), findsOneWidget);

      merchantAddress.value = _other; // the sale of the old user is let go
      await settle(tester);
      expect(destination, findsOneWidget);

      held.complete();
      await settle(tester);

      expect(destination, findsOneWidget);
      expect(find.text(_alias), findsNothing);
      await tester.pump(const Duration(seconds: 30));
      expect(calls(_detailRoute), 0, reason: 'nothing follows the old order');

      // The next sale is not left waiting for the funding that was let go.
      await submit(tester, 'bob@example.com');
      await priceAndConfirm(tester);
      expect(find.text(_alias), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('401 while polling keeps the bank details', (tester) async {
      await toWaiting(tester);
      net.routes[_detailRoute] = (401, {'error': 'invalid api key'});
      await tester.pump(const Duration(seconds: 10));

      expect(tester.takeException(), isNull);
      expect(find.text('La API key no es válida'), findsOneWidget);
      expect(find.text('invalid api key'), findsOneWidget);
      expect(find.text(_alias), findsOneWidget);
      expect(find.text(_cvu), findsOneWidget);
      expect(find.text(r'$ 15.000,37'), findsOneWidget);
      expect(
          tester.getTopLeft(find.text('La API key no es válida')).dy,
          lessThan(tester.getTopLeft(find.text(_alias)).dy),
          reason: 'the reason is above the order');

      // The next tick asks again, and the reason goes once it is answered.
      net.routes[_detailRoute] = orderReply();
      await tester.pump(const Duration(seconds: 10));
      expect(calls(_detailRoute), 2);
      expect(find.text('La API key no es válida'), findsNothing);
      expect(find.text(_alias), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('forgetting the key mid-sale stops the polling and the sale',
        (tester) async {
      await toWaiting(tester);
      await tester.pump(const Duration(seconds: 10));
      expect(calls(_detailRoute), 1);

      await tester.tap(gear);
      await settle(tester);
      await tester.tap(find.byKey(const Key('wapu-forget')));
      await settle(tester);
      expect(find.text(_configure), findsOneWidget);

      await tester.pump(const Duration(seconds: 40));
      expect(calls(_detailRoute), 1, reason: 'nobody to read the order for');

      await tester.tap(setup); // a key again: a new sale, not the old order
      await settle(tester);
      await tester.enterText(find.byKey(const Key('wapu-key')), 'new-key');
      await tester.tap(find.byKey(const Key('wapu-save')));
      await settle(tester);
      expect(destination, findsOneWidget);
      expect(find.text(_alias), findsNothing);
      await tester.pump(const Duration(seconds: 40));
      expect(calls(_detailRoute), 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('another key from the config resets the sale and its poll',
        (tester) async {
      await toWaiting(tester);
      await tester.pump(const Duration(seconds: 10));
      expect(calls(_detailRoute), 1, reason: 'the old key reads the order');

      await tester.tap(gear); // no PIN is set: straight in
      await settle(tester);
      await tester.enterText(find.byKey(const Key('wapu-key')), 'other-key');
      await tester.tap(find.byKey(const Key('wapu-save')));
      await settle(tester);

      expect(find.byType(WapuSettingsScreen), findsNothing);
      expect(destination, findsOneWidget,
          reason: "a new sale: the order was the old key's");
      expect(find.text(_alias), findsNothing);
      expect(fieldText(tester), isEmpty);

      await tester.pump(const Duration(seconds: 40));
      expect(calls(_detailRoute), 1, reason: 'the new key does not read it');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('one client serves the quote, the order and its polls',
        (tester) async {
      var built = 0;
      final make = wapuApiFor;
      wapuApiFor = (baseUrl, apiKey) {
        built++;
        return make(baseUrl, apiKey);
      };

      await toWaiting(tester); // the quote, the create and the funding
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 10));

      expect(calls(_quoteRoute), 1);
      expect(calls(_detailRoute), 2, reason: 'two polls');
      expect(built, 1, reason: 'one client for the key, not one per request');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a key the config swapped gets a client of its own',
        (tester) async {
      await toAmount(tester);
      await price(tester);
      expect(net.keys.last, 'key-1');

      await tester.tap(gear); // no PIN is set: straight in
      await settle(tester);
      await tester.enterText(find.byKey(const Key('wapu-key')), 'other-key');
      await tester.tap(find.byKey(const Key('wapu-save')));
      await settle(tester);
      await submit(tester, 'bob@example.com');
      await price(tester);

      expect(net.calls.last, _quoteRoute);
      expect(net.keys.last, 'other-key',
          reason: 'the price is asked with the new key, not a kept client');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a config closed with the same key keeps the order',
        (tester) async {
      await toWaiting(tester);

      await tester.tap(gear);
      await settle(tester);
      await tester.tap(find.byIcon(Icons.arrow_back)); // nothing changed
      await settle(tester);

      expect(find.byType(WapuSettingsScreen), findsNothing);
      expect(find.text(_alias), findsOneWidget);
      expect(destination, findsNothing);
      await tester.pump(const Duration(seconds: 10));
      expect(calls(_detailRoute), 1, reason: 'and it is still followed');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('new sale asks before abandoning a waiting order',
        (tester) async {
      await toWaiting(tester);

      await tester.tap(newSale);
      await settle(tester);
      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.text('Nueva venta')),
          findsNWidgets(2),
          reason: 'its title and its button');
      expect(
          find.text('La orden queda abierta hasta que venza. '
              'La podés retomar desde el Historial.'),
          findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
      await settle(tester);
      expect(dialog, findsNothing);
      expect(find.text(_alias), findsOneWidget, reason: 'it is still the sale');
      expect(destination, findsNothing);
      await tester.pump(const Duration(seconds: 10));
      expect(calls(_detailRoute), 1, reason: 'and it is still followed');

      await tester.tap(newSale);
      await settle(tester);
      await confirmDialog(tester);
      expect(dialog, findsNothing);
      expect(destination, findsOneWidget);
      expect(fieldText(tester), isEmpty);
      expect(find.text(_alias), findsNothing);

      await tester.pump(const Duration(seconds: 30));
      expect(calls(_detailRoute), 1, reason: 'the old order is not followed');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a sale that got paid while the question was up is not reset',
        (tester) async {
      await toWaiting(tester);
      await tester.tap(newSale);
      await settle(tester);
      expect(find.byType(AlertDialog), findsOneWidget);

      // The customer pays while the operator is still reading the question.
      net.routes[_detailRoute] =
          orderReply(status: 'EXECUTED', payout: 'sending', bank: false);
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('Pago recibido. Enviando los sats…'), findsOneWidget);

      await confirmDialog(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(destination, findsNothing, reason: 'the paid sale is not reset');
      expect(find.text('Pago recibido. Enviando los sats…'), findsOneWidget);

      // It is still followed to the end.
      net.routes[_detailRoute] = completedReply();
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(find.textContaining('¡Listo!'), findsOneWidget);
      expect(paid(), 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("the question of one user does not reset the next user's sale",
        (tester) async {
      seed({_me: 'key-1', _other: 'key-2'});
      await toWaiting(tester);
      await tester.tap(newSale);
      await settle(tester);

      merchantAddress.value = _other; // the till changes hands under the question
      await settle(tester);
      expect(destination, findsOneWidget);
      tester.widget<TextField>(destination).controller!.text =
          'carol@example.com';

      await confirmDialog(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(fieldText(tester), 'carol@example.com',
          reason: 'their sale was not reset');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('two presses in one frame ask the question once',
        (tester) async {
      await toWaiting(tester);

      // Not two tap gestures: after the first one pushes the dialog, the
      // Navigator absorbs every pointer of that frame. This is the other ways
      // in (a key, an accessibility action) pressing the button twice.
      final press = tester.widget<IconButton>(newSale).onPressed!;
      press();
      press(); // the first question is not even built yet
      await settle(tester);
      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
      await settle(tester);
      expect(find.byType(AlertDialog), findsNothing,
          reason: 'there was no second one under the first');
      expect(find.text(_alias), findsOneWidget);

      await tester.tap(newSale); // it was answered: it can be asked again
      await settle(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
      await settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('new sale starts over from the amount without asking',
        (tester) async {
      await toAmount(tester);
      await price(tester);
      expect(confirmAction(tester), isNotNull);

      await tester.tap(newSale);
      await settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(destination, findsOneWidget);
      expect(fieldText(tester), isEmpty, reason: 'the address went with it');

      await submit(tester, 'bob@example.com');
      expect(find.text(r'$ 0'), findsOneWidget, reason: 'a new sale, in pesos');
      expect(find.text('El cliente recibe'), findsNothing,
          reason: 'the old price is gone');
      expect(confirmAction(tester), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('new sale on the first step clears what was typed',
        (tester) async {
      await open(tester);
      await tester.enterText(destination, 'alice@example.com');

      await tester.tap(newSale);
      await settle(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(fieldText(tester), isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    for (final (what, key) in [
      ('the app bar button', 'wapu-new-sale'),
      ('the big button', 'wapu-new-sale-big'),
    ]) {
      testWidgets('$what starts the next sale once the order is done',
          (tester) async {
        await toWaiting(tester);
        net.routes[_detailRoute] = completedReply();
        await tester.pump(const Duration(seconds: 10));
        expect(find.textContaining('¡Listo!'), findsOneWidget);

        await tester.ensureVisible(find.byKey(Key(key)));
        await tester.tap(find.byKey(Key(key)));
        await settle(tester);

        expect(find.byType(AlertDialog), findsNothing,
            reason: 'nothing waits for the customer any more');
        expect(destination, findsOneWidget);
        expect(find.textContaining('¡Listo!'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('Nueva venta stays within reach while the till is locked',
        (tester) async {
      lockedFlow.value = '/wapu';
      await open(tester);

      expect(gear, findsNothing);
      expect(newSale, findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Nueva venta is not offered without a key to sell with',
        (tester) async {
      seed({});
      await open(tester);

      expect(find.text(_configure), findsOneWidget);
      expect(newSale, findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the new sale dialog and button are translated',
        (tester) async {
      await toWaiting(tester, english: true);
      expect(find.byTooltip('NEW SALE'), findsOneWidget);

      await tester.tap(newSale);
      await settle(tester);
      final dialog = find.byType(AlertDialog);
      expect(find.descendant(of: dialog, matching: find.text('New sale')),
          findsNWidgets(2));
      expect(
          find.text('The order stays open until it expires. '
              'You can resume it from the History.'),
          findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await settle(tester);
      await tester.pumpWidget(const SizedBox());
    });
  });

  test('the manifest lists Wapu', () {
    expect(
        miniapps
            .any((m) => m.route == '/wapu' && m.sublabel == 'Bitcoin sin KYC'),
        isTrue);
    final wapu = miniapps.singleWhere((m) => m.route == '/wapu');
    expect(wapu.name, 'Wapu');
    expect(wapu.icon, Icons.currency_bitcoin);
    expect(wapu.requires, isEmpty, reason: 'it needs no device or address');
    expect(miniapps.indexOf(wapu),
        miniapps.indexWhere((m) => m.route == '/cards') + 1,
        reason: 'right after Cards');
    expect(AppLocalizations(AppLanguage.en).tr(wapu.sublabel),
        'Bitcoin without KYC');
  });

  test('lock map covers the subroutes', () {
    expect(lockableFlows['/wapu'],
        containsAll(['/wapu', '/wapu/historial', '/wapu/config']));
  });

  test('the router serves /wapu with its config and history', () {
    final wapu = appRouter.configuration.routes
        .whereType<GoRoute>()
        .singleWhere((r) => r.path == '/wapu');
    expect([for (final r in wapu.routes) (r as GoRoute).path],
        ['config', 'historial']);
  });
}
