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
///
/// [discountSats] is what a coupon took off, so [amountSats] is what was
/// actually charged and the two together give the gross. The ticket has to
/// carry it: it is the customer's only proof the discount was honoured, and the
/// merchant's only paper record of a coupon that was redeemed.
Future<PrintResult> printOrderReceipt({
  required int amountSats,
  required List<OrderItem> items,
  required String thankYouMessage,
  String couponName = '',
  int discountSats = 0,
}) {
  final ars = pricing.satsToFiat(amountSats, Currency.ars);
  final usd = pricing.satsToFiat(amountSats, Currency.usd);
  final btc = pricing.btcUsd; // BTC price in USD (cached, realtime)
  final lines = [
    for (final it in items)
      {
        'name': it.name,
        'price': '${it.priceCurrency.code} '
            '${formatToPreference(it.priceCurrency, it.unitPrice)}',
        'qty': it.qty,
      }
  ];
  // Priced in ARS like the total below it, not in sats: the discount has to be
  // comparable to the number the customer is looking at.
  final discountArs =
      discountSats > 0 ? pricing.satsToFiat(discountSats, Currency.ars) : null;
  final grossArs = discountSats > 0
      ? pricing.satsToFiat(amountSats + discountSats, Currency.ars)
      : null;

  return PrinterChannel.printOrder({
    'items': lines,
    if (grossArs != null)
      'subtotal': 'ARS ${formatToPreference(Currency.ars, grossArs)}',
    if (couponName.isNotEmpty) 'couponName': couponName,
    if (discountArs != null)
      'discount': '-ARS ${formatToPreference(Currency.ars, discountArs)}',
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
