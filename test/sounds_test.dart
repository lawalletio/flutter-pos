import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/core/sounds.dart';
import 'package:lawallet_pos/domain/config/settings_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the touch click plays well below the other cues', () async {
    final played = <String, double>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('pos/sounds'), (call) async {
      if (call.method == 'play') {
        final args = call.arguments as Map;
        played[args['name'] as String] = (args['volume'] as num).toDouble();
      }
      return null;
    });
    appSettings.value = const SettingsState();
    await AppSounds.prepare();

    AppSounds.play(AppSound.button);
    AppSounds.play(AppSound.card);
    await Future<void>.delayed(Duration.zero);

    expect(played['button'], closeTo(0.105, 1e-9));
    expect(played['card'], 1.0);
  });
}
