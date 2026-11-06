import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/core/i18n.dart';
import 'package:lawallet_pos/core/theme.dart';
import 'package:lawallet_pos/domain/config/session.dart';
import 'package:lawallet_pos/features/wapu/wapu_account.dart';
import 'package:lawallet_pos/features/wapu/wapu_api.dart';
import 'package:lawallet_pos/features/wapu/wapu_settings_screen.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

const _me = 'shop@lacrypta.ar';
const _stage = 'https://be-stage.wapu.app';
const _read = 'GET /users/user-settings';
const _write = 'PATCH /users/user-settings';
const _generic = 'No se pudo completar la operación';

/// Answers each request with [routes]`[METHOD path]` → (status, body) and
/// records it. While [hold] is set, every reply waits for it.
class FakeNet implements HttpClientAdapter {
  FakeNet(this.routes);
  final Map<String, (int, Object)> routes;
  final requests = <RequestOptions>[];
  Completer<void>? hold;

  /// `METHOD path` of each request so far.
  List<String> get calls =>
      [for (final r in requests) '${r.method} ${r.uri.path}'];

  @override
  Future<ResponseBody> fetch(
      RequestOptions o, Stream<Uint8List>? _, Future<void>? __) async {
    requests.add(o);
    await hold?.future;
    final (code, body) =
        routes['${o.method} ${o.uri.path}'] ?? (404, {'error': 'nope'});
    return ResponseBody.fromString(jsonEncode(body), code, headers: {
      'content-type': ['application/json']
    });
  }

  @override
  void close({bool force = false}) {}
}

/// A secure store that reads but cannot write, like a full or locked Keystore.
class _ReadOnlyStorage extends FlutterSecureStorage {
  const _ReadOnlyStorage();

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      throw PlatformException(code: 'w');
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

/// A device that already holds [_me]'s key.
void seed({String key = 'saved-key-9999', String url = kWapuDefaultBaseUrl}) =>
    FlutterSecureStorage.setMockInitialValues({
      'wapu.accounts': jsonEncode({
        _me: {'apiKey': key, 'baseUrl': url},
      }),
    });

void main() {
  final realApiFor = wapuApiFor;
  final realAccounts = wapuAccounts;
  late FakeNet net;
  late FakeScanner camera;

  /// The (URL, key) of each client the screen asked for.
  late List<(String, String)> clients;

  /// What the screen popped with, once it has.
  late List<bool?> popped;

  final keyField = find.byKey(const Key('wapu-key'));
  final keyEye = find.byKey(const Key('wapu-key-visibility'));
  final keyScan = find.byKey(const Key('wapu-key-scan'));
  final urlField = find.byKey(const Key('wapu-url'));
  final beta = find.byKey(const Key('wapu-beta'));
  final save = find.byKey(const Key('wapu-save'));
  final forget = find.byKey(const Key('wapu-forget'));

  /// The backend's own message, drawn under the copy of a failed call.
  final detail = find.byKey(const Key('wapu-error-detail'));

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    camera = FakeScanner();
    MobileScannerPlatform.instance = camera;
    merchantAddress.value = _me;
    popped = [];
    clients = [];
    net = FakeNet({
      _read: (200, {'beta_version': false}),
      _write: (200, {'beta_version': true}),
    });
    wapuApiFor = (baseUrl, apiKey) {
      clients.add((baseUrl, apiKey));
      return WapuApi(
          baseUrl: baseUrl,
          apiKey: apiKey,
          dio: Dio()..httpClientAdapter = net);
    };
  });

  tearDown(() {
    merchantAddress.value = '';
    wapuApiFor = realApiFor;
    wapuAccounts = realAccounts;
  });

  /// Lets the storage and the fake network answer (Dio hops through zero-delay
  /// timers, which a bare pump() does not fire) and a route finish moving.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Opens the screen over a home page, so that its pop can be seen.
  Future<void> open(WidgetTester tester, {bool english = false}) async {
    tester.view
      ..physicalSize = const Size(720, 1280) // the Z92's portrait screen
      ..devicePixelRatio = 1.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
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
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context)
                  .push<bool>(MaterialPageRoute(
                      builder: (_) => const WapuSettingsScreen()))
                  .then(popped.add),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.pump(); // the language loads before the home page shows
    await tester.tap(find.text('open'));
    await settle(tester);
  }

  /// The URL field sits in a tile titled [title], which starts closed.
  Future<void> openAdvanced(WidgetTester tester,
      {String title = 'Avanzado'}) async {
    final tile = find.byType(ExpansionTile);
    expect(
        find.descendant(of: tile, matching: find.text(title)), findsOneWidget);
    expect(urlField, findsNothing);

    await tester.tap(tile);
    await settle(tester);
    expect(urlField, findsOneWidget);
  }

  /// Types into the key field and taps Guardar.
  Future<void> saveKey(WidgetTester tester, String key) async {
    await tester.enterText(keyField, key);
    await tester.tap(save);
    await settle(tester);
  }

  /// Taps the QR button, then has the camera read [raw]. With null it closes the
  /// scanner with its X instead, as a merchant who changed their mind would.
  Future<void> scan(WidgetTester tester, String? raw) async {
    const prompt = 'Escaneá el QR de tu API key';
    await tester.tap(keyScan);
    await settle(tester);
    expect(find.text(prompt), findsOneWidget);
    if (raw == null) {
      await tester.tap(find.byIcon(Icons.close));
    } else {
      camera.scans.add(BarcodeCapture(barcodes: [Barcode(rawValue: raw)]));
    }
    await settle(tester);
    expect(find.text(prompt), findsNothing);
  }

  bool switchOn(WidgetTester tester) =>
      tester.widget<SwitchListTile>(beta).value;

  bool keyHidden(WidgetTester tester) =>
      tester.widget<TextField>(keyField).obscureText;

  String keyText(WidgetTester tester) =>
      tester.widget<TextField>(keyField).controller!.text;

  String urlText(WidgetTester tester) =>
      tester.widget<TextField>(urlField).controller!.text;

  String? detailText(WidgetTester tester) => tester.widget<Text>(detail).data;

  /// What the device holds for [_me]. The storage mock answers on real async.
  Future<WapuCredentials?> stored(WidgetTester tester) =>
      tester.runAsync<WapuCredentials?>(() => wapuAccounts.load(_me));

  testWidgets('saving validates the key and turns beta on', (tester) async {
    await open(tester);
    expect(forget, findsNothing); // nothing is saved yet

    await saveKey(tester, 'key-1234');

    final saved = await stored(tester);
    expect(saved?.apiKey, 'key-1234');
    expect(saved?.baseUrl, kWapuDefaultBaseUrl);
    expect(net.calls, [_read, _write]);
    expect(
        jsonDecode(net.requests.last.data as String), {'beta_version': true});
    expect(popped, [true]);
    expect(find.byType(WapuSettingsScreen), findsNothing);
  });

  testWidgets('an invalid key is not saved', (tester) async {
    net.routes[_read] = (401, {'error': 'invalid key'});
    await open(tester);

    await saveKey(tester, 'bad-key');

    expect(find.text('La API key no es válida'), findsOneWidget);
    expect(await stored(tester), isNull);
    expect(net.calls, [_read]);
    expect(popped, isEmpty);
    expect(find.byType(WapuSettingsScreen), findsOneWidget);
  });

  testWidgets('a rejected key shows the backend message as a detail',
      (tester) async {
    net.routes[_read] = (401, {'error': 'invalid api key'});
    await open(tester);

    await saveKey(tester, 'bad-key');

    expect(find.text('La API key no es válida'), findsOneWidget);
    expect(detailText(tester), 'invalid api key');
  });

  testWidgets('one error shows at a time', (tester) async {
    net.routes[_read] = (401, {'error': 'invalid api key'});
    await open(tester);
    await saveKey(tester, 'bad-key');
    expect(find.text('La API key no es válida'), findsOneWidget);
    expect(detail, findsOneWidget);

    // A message of our own takes its place, detail and all.
    await openAdvanced(tester);
    await tester.enterText(urlField, 'http://example.com');
    await tester.tap(save);
    await settle(tester);
    expect(find.text('La URL tiene que empezar con https://'), findsOneWidget);
    expect(find.text('La API key no es válida'), findsNothing);
    expect(detail, findsNothing);

    // And a failed call takes it back.
    await tester.enterText(urlField, kWapuDefaultBaseUrl);
    await tester.tap(save);
    await settle(tester);
    expect(find.text('La URL tiene que empezar con https://'), findsNothing);
    expect(find.text('La API key no es válida'), findsOneWidget);
    expect(detailText(tester), 'invalid api key');
  });

  testWidgets('plain http is rejected', (tester) async {
    await open(tester);
    await openAdvanced(tester);
    await tester.enterText(urlField, 'http://example.com');

    await saveKey(tester, 'key-1234');

    expect(find.text('La URL tiene que empezar con https://'), findsOneWidget);
    expect(detail, findsNothing); // our own message has no backend text
    expect(net.requests, isEmpty);
    expect(await stored(tester), isNull);
    expect(popped, isEmpty);
  });

  // Nothing but the https rule keeps these out of the saved URL: user info
  // would become a Basic header beside the key, and WapuApi appends its paths.
  for (final url in [
    'https://user:pw@be.wapu.app',
    'https://be.wapu.app?x=1',
    'https://be.wapu.app/#top',
    'https://be wapu.app',
  ]) {
    testWidgets('$url is rejected', (tester) async {
      await open(tester);
      await openAdvanced(tester);
      await tester.enterText(urlField, url);

      await saveKey(tester, 'key-1234');

      expect(
          find.text('La URL tiene que empezar con https://'), findsOneWidget);
      expect(detail, findsNothing);
      expect(net.requests, isEmpty);
      expect(await stored(tester), isNull);
    });
  }

  testWidgets('the key and the URL are trimmed, and the URL is normalized',
      (tester) async {
    await open(tester);
    await openAdvanced(tester);
    await tester.enterText(urlField, ' be-stage.wapu.app/ ');

    await saveKey(tester, '  key-1234 ');

    expect(clients, [(_stage, 'key-1234')]);
    expect(net.requests.first.uri.toString(), '$_stage/users/user-settings');
    expect(net.requests.first.headers['X-API-Key'], 'key-1234');
    final saved = await stored(tester);
    expect(saved?.apiKey, 'key-1234');
    expect(saved?.baseUrl, _stage);
    expect(popped, [true]);
  });

  testWidgets('an empty key is refused without a request', (tester) async {
    await open(tester);

    await tester.tap(save); // nothing typed
    await settle(tester);
    expect(find.text('La API key no es válida'), findsOneWidget);
    expect(detail, findsNothing); // refused here, so no backend text

    await saveKey(tester, '   '); // only spaces
    expect(net.requests, isEmpty);
    expect(await stored(tester), isNull);
    expect(popped, isEmpty);
  });

  testWidgets('an empty key field keeps the saved key', (tester) async {
    seed(url: _stage);
    net.routes[_read] = (200, {'beta_version': true});
    await open(tester);
    expect(find.text('Guardada: ••••9999'), findsOneWidget);
    clients.clear();

    await tester.tap(save);
    await settle(tester);

    expect(clients, [(_stage, 'saved-key-9999')]);
    expect(net.requests.last.headers['X-API-Key'], 'saved-key-9999');
    final saved = await stored(tester);
    expect(saved?.apiKey, 'saved-key-9999');
    expect(saved?.baseUrl, _stage);
    expect(net.calls, [_read, _read]); // beta was already on: no PATCH
    expect(popped, [true]);
  });

  testWidgets('saving with the switch off leaves beta alone', (tester) async {
    await open(tester);
    await tester.tap(beta);
    await tester.pump();

    await saveKey(tester, 'key-1234');

    expect(net.calls, [_read]); // beta is off on the account: no PATCH
    expect((await stored(tester))?.apiKey, 'key-1234');
    expect(popped, [true]);
  });

  testWidgets('saving with the switch off turns beta off', (tester) async {
    net.routes[_read] = (200, {'beta_version': true});
    await open(tester);
    expect(switchOn(tester), isTrue); // no saved key: it starts on
    await tester.tap(beta);
    await tester.pump();
    expect(switchOn(tester), isFalse);
    expect(net.requests, isEmpty, reason: 'with no saved key it only waits');

    await saveKey(tester, 'key-1234');

    expect(net.calls, [_read, _write]);
    expect(
        jsonDecode(net.requests.last.data as String), {'beta_version': false});
    expect((await stored(tester))?.apiKey, 'key-1234');
    expect(popped, [true]);
  });

  testWidgets('a storage failure on save says so and stays', (tester) async {
    wapuAccounts = WapuAccounts(storage: const _ReadOnlyStorage());
    await open(tester);

    await saveKey(tester, 'key-1234');

    expect(find.text(_generic), findsOneWidget);
    expect(detail, findsNothing); // the storage is ours, not the backend's
    expect(popped, isEmpty);
    expect(await stored(tester), isNull);
    expect(net.calls, [_read]); // beta is not touched for a key not saved
  });

  testWidgets('a failed beta switch after saving keeps the key and says why',
      (tester) async {
    net.routes[_write] = (503, {'error': 'down'});
    await open(tester);

    await saveKey(tester, 'key-1234');

    expect(find.text('El servicio no está disponible. Probá más tarde.'),
        findsOneWidget);
    expect(detailText(tester), 'down');
    expect((await stored(tester))?.apiKey, 'key-1234');
    expect(popped, isEmpty);
    // The screen shows what is saved, so the key can be forgotten from here.
    expect(forget, findsOneWidget);
    expect(find.text('Guardada: ••••1234'), findsOneWidget);
  });

  testWidgets('with nobody signed in a key is refused, not dropped',
      (tester) async {
    merchantAddress.value = '';
    await open(tester);

    await saveKey(tester, 'key-1234');

    expect(find.text(_generic), findsOneWidget);
    expect(detail, findsNothing);
    expect(net.requests, isEmpty);
    expect(popped, isEmpty);
  });

  testWidgets('a key is saved for the user who opened the screen',
      (tester) async {
    await open(tester);
    merchantAddress.value = 'other@lacrypta.ar'; // the session moves on

    await saveKey(tester, 'key-1234');

    expect((await stored(tester))?.apiKey, 'key-1234');
    final other = await tester.runAsync<WapuCredentials?>(
        () => wapuAccounts.load('other@lacrypta.ar'));
    expect(other, isNull);
  });

  testWidgets('leaving while a save is in flight is harmless', (tester) async {
    net.hold = Completer<void>();
    await open(tester);
    await tester.enterText(keyField, 'key-1234');
    await tester.tap(save);
    await settle(tester);

    tester.state<NavigatorState>(find.byType(Navigator)).pop(); // back out
    await settle(tester);
    expect(find.byType(WapuSettingsScreen), findsNothing);
    net.hold!.complete();
    await settle(tester);

    expect(tester.takeException(), isNull);
    expect((await stored(tester))?.apiKey, 'key-1234'); // it finished anyway
    expect(popped, [null]); // closed by the back, not by the save
  });

  testWidgets('a second tap while saving is ignored', (tester) async {
    net.hold = Completer<void>();
    await open(tester);
    await tester.enterText(keyField, 'key-1234');

    await tester.tap(save);
    await settle(tester);
    await tester.tap(save);
    await settle(tester);
    expect(net.calls, [_read]); // the first one is still waiting for its reply

    net.hold!.complete();
    await settle(tester);
    expect(net.calls, [_read, _write]);
    expect(popped, [true]);
  });

  testWidgets('toggling beta with a saved key patches immediately',
      (tester) async {
    seed(url: _stage);
    net.routes[_read] = (200, {'beta_version': true});
    await open(tester);
    expect(switchOn(tester), isTrue);

    await tester.tap(beta);
    await settle(tester);

    expect(net.calls, [_read, _write]);
    expect(clients.last, (_stage, 'saved-key-9999'));
    expect(
        jsonDecode(net.requests.last.data as String), {'beta_version': false});
    expect(switchOn(tester), isFalse);
    expect(popped, isEmpty); // the switch applies itself: nothing to save
  });

  testWidgets('a failed toggle reverts the switch and says why',
      (tester) async {
    seed();
    net.routes[_read] = (200, {'beta_version': true});
    net.routes[_write] = (401, {'error': 'invalid key'});
    await open(tester);

    await tester.tap(beta);
    await settle(tester);

    expect(find.text('La API key no es válida'), findsOneWidget);
    expect(detailText(tester), 'invalid key');
    expect(switchOn(tester), isTrue);
    expect(net.calls, [_read, _write]);
  });

  testWidgets('without a saved key the switch starts on and sends nothing',
      (tester) async {
    await open(tester);
    expect(switchOn(tester), isTrue);
    await openAdvanced(tester);
    expect(urlText(tester), kWapuDefaultBaseUrl);

    await tester.tap(beta);
    await settle(tester);

    expect(switchOn(tester), isFalse);
    expect(net.requests, isEmpty);
  });

  testWidgets('a saved key sets the switch from the account', (tester) async {
    seed(url: _stage);
    net.routes[_read] = (200, {'beta_version': false});

    await open(tester);

    expect(switchOn(tester), isFalse);
    expect(clients, [(_stage, 'saved-key-9999')]);
    expect(net.requests.single.headers['X-API-Key'], 'saved-key-9999');
    await openAdvanced(tester);
    expect(urlText(tester), _stage);
  });

  testWidgets('the controls wait while the account is read', (tester) async {
    seed();
    net.hold = Completer<void>();
    await open(tester);

    // The saved key shows at once, but nothing can act on it yet.
    expect(find.text('Guardada: ••••9999'), findsOneWidget);
    expect(forget, findsOneWidget);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(tester.widget<TextButton>(forget).onPressed, isNull);
    expect(tester.widget<SwitchListTile>(beta).onChanged, isNull);

    net.hold!.complete();
    await settle(tester);

    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    expect(tester.widget<TextButton>(forget).onPressed, isNotNull);
    expect(tester.widget<SwitchListTile>(beta).onChanged, isNotNull);
  });

  testWidgets('a failed read says why, and the key can still be replaced',
      (tester) async {
    seed();
    net.routes[_read] = (401, {'error': 'invalid key'});

    await open(tester);

    expect(find.text('La API key no es válida'), findsOneWidget);
    expect(detailText(tester), 'invalid key');
    expect(switchOn(tester), isTrue);
    expect(find.text('Guardada: ••••9999'), findsOneWidget);
    expect(forget, findsOneWidget);
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);

    net.routes[_read] = (200, {'beta_version': true});
    await saveKey(tester, 'new-key-0000');

    expect((await stored(tester))?.apiKey, 'new-key-0000');
    expect(popped, [true]);
  });

  testWidgets('forget removes the key', (tester) async {
    seed();
    await open(tester);

    await tester.tap(forget);
    await settle(tester);

    expect(await stored(tester), isNull);
    expect(popped, [true]);
    expect(find.byType(WapuSettingsScreen), findsNothing);
  });

  testWidgets('a storage failure on forget says so and stays', (tester) async {
    seed();
    wapuAccounts = WapuAccounts(storage: const _ReadOnlyStorage());
    await open(tester);

    await tester.tap(forget);
    await settle(tester);

    expect(find.text(_generic), findsOneWidget);
    expect(detail, findsNothing);
    expect(popped, isEmpty);
    expect((await stored(tester))?.apiKey, 'saved-key-9999');
    expect(forget, findsOneWidget);
  });

  testWidgets('the key is hidden until the eye is tapped, and hides again',
      (tester) async {
    await open(tester);
    expect(keyHidden(tester), isTrue, reason: 'hidden by default');
    expect(find.byIcon(Icons.visibility), findsOneWidget);
    expect(find.byTooltip('Mostrar la API key'), findsOneWidget);

    await tester.tap(keyEye);
    await tester.pump();
    expect(keyHidden(tester), isFalse);
    expect(find.byIcon(Icons.visibility_off), findsOneWidget);
    expect(find.byTooltip('Ocultar la API key'), findsOneWidget);

    await tester.tap(keyEye);
    await tester.pump();
    expect(keyHidden(tester), isTrue);
    expect(find.byIcon(Icons.visibility), findsOneWidget);
  });

  testWidgets('scanning a QR fills the key field, and Guardar sends that key',
      (tester) async {
    await open(tester);
    expect(find.byIcon(Icons.qr_code_scanner), findsOneWidget);
    expect(find.byTooltip('Escanear la API key'), findsOneWidget);
    await tester.enterText(keyField, 'typed-by-hand');

    await scan(tester, 'first-scan');
    expect(keyText(tester), 'first-scan', reason: 'in place of what was typed');
    expect(keyHidden(tester), isTrue, reason: 'the eye left it hidden');

    await tester.tap(keyEye);
    await tester.pump();
    await scan(tester, '  wapu_test_key\n');
    expect(keyText(tester), 'wapu_test_key', reason: 'trimmed');
    expect(keyHidden(tester), isFalse, reason: 'the eye left it shown');

    await tester.tap(save);
    await settle(tester);

    expect(clients, [(kWapuDefaultBaseUrl, 'wapu_test_key')]);
    expect(net.requests.first.headers['X-API-Key'], 'wapu_test_key');
    expect((await stored(tester))?.apiKey, 'wapu_test_key');
    expect(popped, [true]);
  });

  testWidgets('a closed scanner or an empty code leaves the typed key alone',
      (tester) async {
    await open(tester);
    await tester.enterText(keyField, 'typed-by-hand');

    await scan(tester, null); // the X
    expect(keyText(tester), 'typed-by-hand');

    await scan(tester, ' \n'); // a code with nothing in it
    expect(keyText(tester), 'typed-by-hand');
  });

  testWidgets('the screen is translated', (tester) async {
    seed();
    await open(tester, english: true);

    expect(find.text('Wapu settings'), findsOneWidget);
    expect(find.text('Saved: ••••9999'), findsOneWidget);
    expect(find.text('Forget key'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.byTooltip('Show the API key'), findsOneWidget);
    await tester.tap(keyEye);
    await tester.pump();
    expect(find.byTooltip('Hide the API key'), findsOneWidget);
    expect(find.byTooltip('Scan the API key'), findsOneWidget);
    await tester.tap(keyScan);
    await settle(tester);
    expect(find.text('Scan your API key QR code'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await settle(tester);
    await openAdvanced(tester, title: 'Advanced');
    expect(find.text('Backend URL'), findsOneWidget);

    await tester.enterText(urlField, 'http://example.com');
    await tester.tap(save);
    await settle(tester);

    expect(find.text('The URL must start with https://'), findsOneWidget);
  });
}
