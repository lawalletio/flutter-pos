import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/core/app_update.dart';

void main() {
  test('isNewerVersion compares x.y.z numerically', () {
    expect(isNewerVersion('v0.5.0', '0.4.0'), isTrue);
    expect(isNewerVersion('v0.4.10', '0.4.9'), isTrue);
    expect(isNewerVersion('v1.0.0', '0.99.99'), isTrue);
    expect(isNewerVersion('v0.4.0', '0.4.0'), isFalse);
    expect(isNewerVersion('v0.3.9', '0.4.0'), isFalse);
  });

  test('pickApk prefers the ABI split, else the universal APK', () {
    const base = 'https://x/lawallet-pos-v0.5.0';
    final urls = ['$base-arm64-v8a.apk', '$base-armeabi-v7a.apk', '$base.apk'];
    expect(pickApk(urls, 'armeabi-v7a'), '$base-armeabi-v7a.apk');
    expect(pickApk(urls, 'arm64-v8a'), '$base-arm64-v8a.apk');
    expect(pickApk(urls, 'x86_64'), '$base.apk');
    expect(pickApk(['$base-arm64-v8a.apk'], 'x86_64'), isNull);
  });
}
