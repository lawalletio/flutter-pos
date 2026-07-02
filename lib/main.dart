import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'data/pricing/block_service.dart';
import 'data/pricing/pricing_service.dart';
import 'domain/config/address_history.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // POS runs portrait-locked (matches the wrapper).
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  // Keep BTC rates + block height warm and refreshed so the ticket data (BTC
  // price, block number, fiat totals) is instantly available when printing —
  // no network round-trip while the receipt is being composed.
  pricing.startAutoRefresh();
  blockHeight.startAutoRefresh();
  // Load the saved Lightning-address history.
  addressHistory.load();
  runApp(const ProviderScope(child: LaWalletPosApp()));
}
