import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/config/settings_state.dart';

/// Short cues for the till. Each event has its own file so they stay distinct
/// even when two happen close together.
enum AppSound { start, button, invoice, card, paid, tick, win, miss, casino, heartbeat }

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
    AppSound.win: 'sounds/prize_loquita.wav',
    AppSound.miss: 'sounds/miss_life.wav',
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
    await _loadPcm(AppSound.tick.name, _tickPcm());
    await _loadPcm(AppSound.casino.name, _casinoPcm());
    await _loadPcm(AppSound.heartbeat.name, _heartbeatPcm());
    _ready = true;
  }

  static Future<void> _load(String name, String asset) async {
    final bytes = await rootBundle.load('assets/$asset');
    final wav = _WavPcm.parse(bytes);
    await _loadPcm(name, wav.pcm, rate: wav.sampleRate, channels: wav.channels);
  }

  static Future<void> _loadPcm(
    String name,
    Uint8List pcm, {
    int rate = 44100,
    int channels = 2,
  }) {
    return _channel.invokeMethod<void>('load', {
      'name': name,
      'rate': rate,
      'channels': channels,
      'pcm': pcm,
    });
  }

  static void play(AppSound sound, {bool loop = false}) {
    if (!_ready) return;
    final settings = appSettings.value;
    if (!settings.soundEnabled) return;
    final specific = switch (sound) {
      AppSound.button => settings.touchVolume,
      AppSound.paid => settings.paidVolume,
      _ => 1.0,
    };
    final gain = (settings.soundVolume * specific).clamp(0.0, 1.0);
    if (gain <= 0) return;
    if (sound == AppSound.button) {
      final now = DateTime.now();
      final last = _lastButton;
      if (last != null && now.difference(last) < const Duration(milliseconds: 50)) {
        return;
      }
      _lastButton = now;
    }
    final name = sound == AppSound.paid
        ? paidSoundById(settings.paidSoundId).id
        : sound.name;
    _channel.invokeMethod<void>('play', {
      'name': name,
      'volume': gain,
      'loop': loop,
    }).then(
      (_) {},
      onError: (Object e) {
        debugPrint('AppSounds: $e');
      },
    );
  }

  static void stop(AppSound sound) {
    if (!_ready) return;
    _channel.invokeMethod<void>('stop', {'name': sound.name}).then(
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

const _pcmRate = 44100;

/// Metallic peg click. Short enough to retrigger on every wedge.
Uint8List _tickPcm() {
  final count = (_pcmRate * 0.042).round();
  final out = List<double>.filled(count, 0);
  var noise = 0.37;
  for (var i = 0; i < count; i++) {
    final t = i / _pcmRate;
    final click = math.exp(-t * 260);
    final ring = math.exp(-t * 70);
    noise = (noise * 91.7 + 0.13) % 1;
    final grit = (noise * 2 - 1) * click;
    final metal = math.sin(2 * math.pi * 2480 * t) * 0.55 +
        math.sin(2 * math.pi * 3720 * t) * 0.28;
    out[i] = (grit * 0.8 + metal * ring) * 0.92;
  }
  return _stereo(out);
}

/// Bright looping slot bed: chime ostinato plus a spinning reel bed.
Uint8List _casinoPcm() {
  final count = (_pcmRate * 2).round();
  final out = List<double>.filled(count, 0);
  const notes = [523.25, 659.25, 783.99, 1046.5];
  for (var i = 0; i < count; i++) {
    final t = i / _pcmRate;
    final step = (t * 8).floor() % notes.length;
    final local = t * 8 - (t * 8).floor();
    final env = math.exp(-local * 7.2);
    final tone = math.sin(2 * math.pi * notes[step] * t) * 0.38 * env +
        math.sin(2 * math.pi * notes[step] * 2 * t) * 0.12 * env;
    final bed = math.sin(2 * math.pi * 196 * t) * 0.08 +
        math.sin(2 * math.pi * 98 * t) * 0.05;
    final shimmer = math.sin(2 * math.pi * 2349 * t) *
        0.07 *
        (0.5 + 0.5 * math.sin(2 * math.pi * 6 * t));
    out[i] = (tone + bed + shimmer).clamp(-1.0, 1.0);
  }
  return _stereo(out);
}

/// Two-beat pulse that loops while the wheel coasts to a stop.
Uint8List _heartbeatPcm() {
  final count = (_pcmRate * 0.72).round();
  final out = List<double>.filled(count, 0);
  const lub = 0.0;
  const dub = 0.16;
  for (var i = 0; i < count; i++) {
    final t = i / _pcmRate;
    double hit(double at) {
      final d = t - at;
      if (d < 0 || d > 0.14) return 0;
      final body = math.exp(-d * 38) * math.sin(2 * math.pi * 58 * d);
      final thump = math.exp(-d * 22) * math.sin(2 * math.pi * 36 * d);
      return body * 0.82 + thump * 0.55;
    }

    out[i] = (hit(lub) + hit(dub) * 0.86).clamp(-1.0, 1.0);
  }
  return _stereo(out);
}

Uint8List _stereo(List<double> mono) {
  final bytes = Uint8List(mono.length * 4);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < mono.length; i++) {
    final sample = (mono[i].clamp(-1.0, 1.0) * 32767).round();
    data.setInt16(i * 4, sample, Endian.little);
    data.setInt16(i * 4 + 2, sample, Endian.little);
  }
  return bytes;
}
