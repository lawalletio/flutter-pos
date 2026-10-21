import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/features/cards/cards_widgets.dart';

Future<ByteData> _render(Size size, void Function(Canvas canvas) paint) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..drawRect(Offset.zero & size, Paint()..color = Colors.black)
    // The card's clip.
    ..clipRect(Offset.zero & size);
  paint(canvas);
  final image = await recorder
      .endRecording()
      .toImage(size.width.toInt(), size.height.toInt());
  return (await image.toByteData())!;
}

void main() {
  test('SheenPainter paints the same pixels as the diagonal LinearGradient',
      () async {
    const size = Size(317, 200);
    // Rest, both ends of the tilt, and in between.
    for (final (sx, sy) in [(0.0, 0.0), (1.0, 0.7), (-1.0, -0.7), (0.4, -0.3)]) {
      final gradient = LinearGradient(
        begin: Alignment(-1.6 + sx, -1.6 + sy),
        end: Alignment(1.6 + sx, 1.6 + sy),
        colors: [
          Colors.transparent,
          Colors.white.withValues(alpha: 0.16),
          Colors.white.withValues(alpha: 0.30),
          Colors.white.withValues(alpha: 0.16),
          Colors.transparent,
        ],
      );
      final want = await _render(
          size,
          (c) => c.drawRect(Offset.zero & size,
              Paint()..shader = gradient.createShader(Offset.zero & size)));
      final got =
          await _render(size, (c) => SheenPainter(sx, sy).paint(c, size));
      var diff = 0;
      for (var i = 0; i < want.lengthInBytes; i++) {
        diff = (want.getUint8(i) - got.getUint8(i)).abs().clamp(diff, 255);
      }
      expect(diff, lessThanOrEqualTo(2), reason: 'sx=$sx sy=$sy');
    }
  });
}
