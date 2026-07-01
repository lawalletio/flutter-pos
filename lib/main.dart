import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'data/pricing/pricing_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // POS runs portrait-locked (matches the wrapper).
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  // Warm up BTC rates for fiat↔sats conversion (non-blocking).
  pricing.ensureLoaded();
  runApp(const ProviderScope(child: LaWalletPosApp()));
}
