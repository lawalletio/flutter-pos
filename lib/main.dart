import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/sounds.dart';
import 'data/lnurl/lnurl_service.dart';
import 'data/nostr/catalog_service.dart';
import 'data/nostr/identity.dart';
import 'data/pricing/block_service.dart';
import 'data/pricing/pricing_service.dart';
import 'domain/config/address_history.dart';
import 'domain/config/settings_persistence.dart';
import 'domain/config/session.dart';
import 'domain/order/invoice_debug_store.dart';
import 'domain/order/orders_store.dart';

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
  // Load the saved Lightning-address history + order history (empty on a fresh
  // install; both persist across restarts).
  addressHistory.load();
  settingsPersistence.load();
  ordersStore.load();
  invoiceDebugStore.load();
  // Warm the invoice path so the FIRST charge is just the provider callback:
  // load + derive the Nostr identity (BIP-340 pubkey, done once) and pre-resolve
  // the merchant LUD-16 address — both otherwise happen inline on that first
  // invoice request. Fire-and-forget; errors are irrelevant here.
  nostrIdentity.publicKey().ignore();
  lnurl.resolve(merchantAddress.value).ignore();
  // Same idea for the menu: resolve NIP-05 and pull the merchant's NIP-99
  // catalog now, so opening the menu paints instead of spinning. Serves the
  // persisted copy first, then revalidates against the relays.
  catalog.ensureLoaded(merchantAddress.value).ignore();
  try {
    await AppSounds.prepare();
  } catch (e) {
    debugPrint('AppSounds: $e');
  }
  runApp(const ProviderScope(child: LaWalletPosApp()));
  WidgetsBinding.instance.addPostFrameCallback((_) {
    AppSounds.play(AppSound.start);
  });
}
