import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/core/app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';

const _base = 'https://x/lawallet-pos-v9.0.0';

/// GitHub's latest release, then the APK bytes; or a network error.
class _FakeGitHub implements HttpClientAdapter {
  String tag = 'v9.0.0';
  bool fail = false;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (fail) throw DioException(requestOptions: options, message: 'offline');
    if (options.uri.path.endsWith('.apk')) {
      return ResponseBody.fromBytes([1, 2, 3, 4], 200,
          headers: {
            Headers.contentLengthHeader: ['4'],
          });
    }
    return ResponseBody.fromString(
      jsonEncode({
        'tag_name': tag,
        'body': '## Novedades\n- **Rápido** `ok`',
        'assets': [
          {'browser_download_url': '$_base-arm64-v8a.apk'},
          {'browser_download_url': '$_base-armeabi-v7a.apk'},
          {'browser_download_url': '$_base.apk'},
        ],
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final android = TargetPlatformVariant.only(TargetPlatform.android);
  late _FakeGitHub github;
  late List<String> installed;
  var fromStore = false;
  final dir = Directory.systemTemp.createTempSync('update_test');

  setUp(() {
    github = _FakeGitHub();
    updateDio = Dio()..httpClientAdapter = github;
    installed = [];
    fromStore = false;
    PackageInfo.setMockInitialValues(
        appName: 'pos',
        packageName: 'pos',
        version: '0.4.0',
        buildNumber: '17',
        buildSignature: '');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('pos/update'),
            (call) async {
      if (call.method == 'info') {
        return {'abi': 'armeabi-v7a', 'dir': dir.path, 'fromStore': fromStore};
      }
      installed.add((call.arguments as Map)['path'] as String);
      return null;
    });
  });

  test('isNewerVersion compares x.y.z numerically', () {
    expect(isNewerVersion('v0.5.0', '0.4.0'), isTrue);
    expect(isNewerVersion('v0.4.10', '0.4.9'), isTrue);
    expect(isNewerVersion('v1.0.0', '0.99.99'), isTrue);
    expect(isNewerVersion('v0.4.0', '0.4.0'), isFalse);
    expect(isNewerVersion('v0.3.9', '0.4.0'), isFalse);
  });

  test('pickApk prefers the ABI split, else the universal APK', () {
    final urls = [
      '$_base-arm64-v8a.apk',
      '$_base-armeabi-v7a.apk',
      '$_base.apk'
    ];
    expect(pickApk(urls, 'armeabi-v7a'), '$_base-armeabi-v7a.apk');
    expect(pickApk(urls, 'arm64-v8a'), '$_base-arm64-v8a.apk');
    expect(pickApk(urls, 'x86_64'), '$_base.apk');
    expect(pickApk(['$_base-arm64-v8a.apk'], 'x86_64'), isNull);
  });

  group('checkForUpdate', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('finds the newer release with the ABI APK and plain notes', () async {
      final update = (await checkForUpdate())!;
      expect(update.version, 'v9.0.0');
      expect(update.apkUrl, '$_base-armeabi-v7a.apk');
      expect(update.notes, 'Novedades\n- Rápido ok');
      expect(await canSelfUpdate(), isTrue);
    });

    test('nothing when already on the latest release', () async {
      github.tag = 'v0.4.0';
      expect(await checkForUpdate(), isNull);
    });

    test('nothing for Play installs', () async {
      fromStore = true;
      expect(await checkForUpdate(), isNull);
      expect(await canSelfUpdate(), isFalse);
    });

    test('nothing off Android', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(await checkForUpdate(), isNull);
      expect(await canSelfUpdate(), isFalse);
    });
  });

  /// Lets the fake network answer (Dio hops through zero-delay timers, which a
  /// bare pump() does not fire); the download's file write is real I/O.
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() => Future.delayed(Duration.zero));
    }
  }

  Future<void> pumpHost(WidgetTester tester, Widget child) => tester
      .pumpWidget(MaterialApp(home: Scaffold(body: Center(child: child))));

  testWidgets('dialog downloads with progress and opens the installer',
      (tester) async {
    await pumpHost(
        tester,
        Builder(
            builder: (context) => TextButton(
                onPressed: () => showUpdateDialog(
                    context, const AppUpdate('v9.0.0', '$_base.apk', 'Notas')),
                child: const Text('open'))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Notas'), findsOneWidget);

    await tester.tap(find.text('Actualizar'));
    for (var i = 0; i < 100 && installed.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester
          .runAsync(() => Future.delayed(const Duration(milliseconds: 20)));
    }
    await tester.pumpAndSettle();

    expect(installed, ['${dir.path}/lawallet-pos-update.apk']);
    expect(File(installed.single).readAsBytesSync(), [1, 2, 3, 4]);
    expect(find.text('Notas'), findsNothing); // dialog closed
  }, variant: android);

  testWidgets('a failed download shows the error and offers a retry',
      (tester) async {
    github.fail = true;
    await pumpHost(
        tester,
        Builder(
            builder: (context) => TextButton(
                onPressed: () => showUpdateDialog(
                    context, const AppUpdate('v9.0.0', '$_base.apk', '')),
                child: const Text('open'))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Actualizar'));
    await settleIo(tester);

    expect(find.text('offline'), findsOneWidget);
    expect(find.text('Reintentar'), findsOneWidget);
    expect(installed, isEmpty);
    await tester.tap(find.text('Más tarde'));
    await tester.pumpAndSettle();
    expect(find.text('Reintentar'), findsNothing);
  }, variant: android);

  testWidgets('startup check opens the dialog only for a new release',
      (tester) async {
    await pumpHost(tester, const SizedBox());
    final context = tester.element(find.byType(SizedBox));
    autoCheckForUpdate(() => context);
    await settleIo(tester);
    expect(find.text('Novedades\n- Rápido ok'), findsOneWidget);

    github.fail = true; // errors stay silent
    autoCheckForUpdate(() => context);
    await settleIo(tester);
  }, variant: android);

  group('CheckUpdatesButton', () {
    Future<void> tapCheck(WidgetTester tester) async {
      await pumpHost(tester, const CheckUpdatesButton());
      await settleIo(tester);
      await tester.tap(find.text('Buscar actualizaciones'));
      await settleIo(tester);
    }

    testWidgets('opens the dialog when a release is newer', (tester) async {
      await tapCheck(tester);
      expect(find.text('Actualizar'), findsOneWidget);
    }, variant: android);

    testWidgets('says when already up to date', (tester) async {
      github.tag = 'v0.4.0';
      await tapCheck(tester);
      expect(find.text('Ya tenés la última versión'), findsOneWidget);
    }, variant: android);

    testWidgets('reports a failed check', (tester) async {
      github.fail = true;
      await tapCheck(tester);
      expect(find.text('No se pudo buscar actualizaciones'), findsOneWidget);
    }, variant: android);

    testWidgets('hidden where the app cannot self-update', (tester) async {
      await pumpHost(tester, const CheckUpdatesButton());
      await tester.pumpAndSettle();
      expect(find.text('Buscar actualizaciones'), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });
}
