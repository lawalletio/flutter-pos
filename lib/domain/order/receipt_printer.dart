import '../../data/pricing/block_service.dart';
import '../../data/pricing/pricing_service.dart';
import '../../platform/printer_channel.dart';
import '../config/currencies.dart';
import '../config/formatter.dart';
import 'current_order.dart';

/// Builds the ZCS print job for a paid order and sends it to the printer.
///
/// Shared by the live payment flow and the Orders "Checkear" re-verification so
/// both produce an identical ticket: the [items] as line entries plus ARS/USD/sat
/// totals, the current block height and BTC price (kept warm in memory — no
/// print-time network delay), and a closing [thankYouMessage].
///
/// A no-op where there's no printer (e.g. web preview): the channel returns a
/// graceful "not available" [PrintResult] instead of throwing.
Future<PrintResult> printOrderReceipt({
  required int amountSats,
  required List<OrderItem> items,
  required String thankYouMessage,
}) {
  final ars = pricing.satsToFiat(amountSats, Currency.ars);
  final usd = pricing.satsToFiat(amountSats, Currency.usd);
  final btc = pricing.btcUsd; // BTC price in USD (cached, realtime)
  final lines = [
    for (final it in items)
      {
        'name': it.name,
        'price': formatToPreference(Currency.ars, it.unitPrice),
        'qty': it.qty,
      }
  ];
  return PrinterChannel.printOrder({
    'items': lines,
    'currency': 'ARS',
    'total': ars != null ? formatToPreference(Currency.ars, ars) : '-',
    'currencyB': 'USD',
    'totalB': usd != null ? formatToPreference(Currency.usd, usd) : '-',
    'totalSats': formatToPreference(Currency.sat, amountSats),
    'blockNumber': blockHeight.height?.toString() ?? '',
    'btcPrice': btc != null ? formatToPreference(Currency.ars, btc) : '',
    'message': thankYouMessage,
  });
}
