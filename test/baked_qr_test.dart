import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lawallet_pos/core/widgets.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  testWidgets('the QR bitmap fits whole modules, so no edge is cut',
      (tester) async {
    final qr = QrValidator.validate(
      data: 'LNBC' * 60,
      version: QrVersions.auto,
    ).qrCode!;
    final n = qr.moduleCount;
    // A side whose module size rounds UP to the next half pixel: QrPainter
    // alone would draw the code wider than this and crop it.
    final side = n * 6.8;
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: BakedQr(
          size: side,
          moduleCount: n,
          painter: QrPainter.withQr(qr: qr, gapless: true),
        ),
      ),
    ));
    final image = tester.widget<RawImage>(find.byType(RawImage)).image!;
    final dpr = tester.view.devicePixelRatio;
    expect(image.width, lessThanOrEqualTo(side * dpr));
    expect((image.width / n * 2) % 1, 0);
  });
}
