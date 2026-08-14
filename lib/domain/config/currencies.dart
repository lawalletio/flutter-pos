/// Currencies supported by the POS. Ported from `src/types/config.ts`.
enum Currency { sat, usd, ars }

extension CurrencyX on Currency {
  String get code {
    switch (this) {
      case Currency.sat:
        return 'SAT';
      case Currency.usd:
        return 'USD';
      case Currency.ars:
        return 'ARS';
    }
  }

  /// Intl locale used for formatting (mirrors `CurrenciesMetadata`).
  String get locale => this == Currency.usd ? 'en-US' : 'es-AR';

  /// Parse a currency code, or null when it is not one this POS can charge.
  ///
  /// Returns null rather than a default ON PURPOSE. The previous `fromCode`
  /// funnelled every unrecognised code into [Currency.sat], so a NIP-99 product
  /// priced `["price","25","EUR"]` became 25 satoshis — a ~1000x undercharge —
  /// and it mapped `BTC` to `sat` as though one bitcoin were one satoshi.
  /// Wire data must be refused, never guessed at.
  ///
  /// `BTC` and `SATS` are absent here deliberately: `parsePriceTag` folds both
  /// into `SAT` (converting the amount) before this is ever consulted.
  static Currency? tryFromCode(String code) {
    switch (code.trim().toUpperCase()) {
      case 'ARS':
        return Currency.ars;
      case 'USD':
        return Currency.usd;
      case 'SAT':
        return Currency.sat;
      default:
        return null;
    }
  }
}

const List<Currency> currenciesList = [Currency.sat, Currency.usd, Currency.ars];
