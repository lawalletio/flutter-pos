import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/config/settings_state.dart';

/// Short cues for the till. Each event has its own file so they stay distinct
/// even when two happen close together.
enum AppSound { start, button, invoice, card, paid }

/// Choices for the successful-payment cue. [id] is what gets persisted.
class PaidSoundOption {
  const PaidSoundOption(this.id, this.label, this.asset);

  final String id;
  final String label;
  final String asset;
}

const paidSoundOptions = <PaidSoundOption>[
  PaidSoundOption('arpeggio', 'Arpegio', 'sounds/paid.wav'),
  PaidSoundOption('sapeee', 'Sapeee', 'sounds/paid_bananero.wav'),
];

const kDefaultPaidSoundId = 'arpeggio';

PaidSoundOption paidSoundById(String? id) {
  for (final option in paidSoundOptions) {
    if (option.id == id) return option;
  }
  return paidSoundOptions.first;
}

class AppSounds {
  static const _channel = MethodChannel('pos/sounds');
  static var _ready = false;
  static DateTime? _lastButton;

  static const _files = {
    AppSound.start: 'sounds/start.wav',
    AppSound.button: 'sounds/button.wav',
    AppSound.invoice: 'sounds/invoice.wav',
    AppSound.card: 'sounds/card.wav',
  };

  /// Decode each cue and hand the PCM to Android. Safe to call more than once.
  ///
  /// Playback goes straight to an [AudioTrack] with an explicit speaker mask.
  /// The emulator's media player drops these clips before they reach the speaker.
  static Future<void> prepare() async {
    if (_ready) return;
    for (final sound in _files.entries) {
      await _load(sound.key.name, sound.value);
    }
    for (final option in paidSoundOptions) {
      await _load(option.id, option.asset);
    }
    _ready = true;
  }

  static Future<void> _load(String name, String asset) async {
    final bytes = await rootBundle.load('assets/$asset');
    final wav = _WavPcm.parse(bytes);
    await _channel.invokeMethod<void>('load', {
      'name': name,
      'rate': wav.sampleRate,
      'channels': wav.channels,
      'pcm': wav.pcm,
    });
  }

  static void play(AppSound sound) {
    if (!_ready) return;
    if (sound == AppSound.button) {
      final now = DateTime.now();
      final last = _lastButton;
      if (last != null && now.difference(last) < const Duration(milliseconds: 50)) {
        return;
      }
      _lastButton = now;
    }
    final name = sound == AppSound.paid
        ? paidSoundById(appSettings.value.paidSoundId).id
        : sound.name;
    _channel.invokeMethod<void>('play', {'name': name}).then(
      (_) {},
      onError: (Object e) {
        debugPrint('AppSounds: $e');
      },
    );
  }
}

class _WavPcm {
  _WavPcm(this.sampleRate, this.channels, this.pcm);

  final int sampleRate;
  final int channels;
  final Uint8List pcm;

  static _WavPcm parse(ByteData data) {
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final channels = _u16(bytes, 22);
    final rate = _u32(bytes, 24);
    var i = 12;
    while (i + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(i, i + 4));
      final size = _u32(bytes, i + 4);
      if (id == 'data') {
        final start = i + 8;
        return _WavPcm(rate, channels, bytes.sublist(start, start + size));
      }
      i += 8 + size + (size & 1);
    }
    throw StateError('WAV sin datos');
  }

  static int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
  static int _u32(Uint8List b, int o) =>
      b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
}
