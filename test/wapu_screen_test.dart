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
import 'package:lawallet_pos/core/theme.dart';
import 'package:lawallet_pos/data/lnurl/lnurl_service.dart';
import 'package:lawallet_pos/domain/config/miniapp_pin.dart';
import 'package:lawallet_pos/domain/config/session.dart';
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

  /// Holds each request until the future it returns completes, when set. The
  /// answer is the one routed when the request came in, not when it is let go.
  Future<void> Function(RequestOptions o)? hold;

  @override
  Future<ResponseBody> fetch(
      RequestOptions o, Stream<Uint8List>? _, Future<void>? __) async {
    final key = '${o.method} ${o.uri.path}';
    calls.add(key);
    queries.add(o.uri.queryParameters);
    final (code, body) = routes[key] ?? (404, {'error': 'nope'});
    await hold?.call(o);
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

    testWidgets('a base URL changed in the config drops the old quote',
        (tester) async {
      final asked =
          <String>[]; // the backend of each client the screens ask for
      final swapped = wapuApiFor;
      wapuApiFor = (baseUrl, apiKey) {
        asked.add(baseUrl);
        return swapped(baseUrl, apiKey);
      };
      await toAmount(tester);
      await typeDigits(tester, '15000');
      await tester.pump(const Duration(milliseconds: 600));
      expect(line('El cliente recibe', '12.500 sats'), findsOneWidget);
      expect(confirmAction(tester), isNotNull);

      await tester.tap(gear); // no PIN is set: straight in
      await settle(tester);
      await tester.tap(find.byType(ExpansionTile)); // Avanzado
      await settle(tester);
      await tester.enterText(
          find.byKey(const Key('wapu-url')), 'be-stage.wapu.app');
      await tester.tap(find.byKey(const Key('wapu-save'))); // keeps the key
      await settle(tester);

      expect(find.byType(WapuSettingsScreen), findsNothing);
      expect(amount, findsOneWidget,
          reason: 'the sale goes on from the amount');
      expect(find.text('\$ 0'), findsOneWidget);
      expect(find.text('El cliente recibe'), findsNothing,
          reason: "the old backend's price is not the new one's");
      expect(confirmAction(tester), isNull);

      await typeDigits(tester, '15000');
      await tester.pump(const Duration(milliseconds: 600));
      expect(line('El cliente recibe', '12.500 sats'), findsOneWidget);
      expect(confirmAction(tester), isNotNull);
      expect(asked.first, kWapuDefaultBaseUrl);
      expect(asked.last, 'https://be-stage.wapu.app',
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

  test('the router serves /wapu with its config', () {
    final wapu = appRouter.configuration.routes
        .whereType<GoRoute>()
        .singleWhere((r) => r.path == '/wapu');
    expect([for (final r in wapu.routes) (r as GoRoute).path], ['config']);
  });
}
