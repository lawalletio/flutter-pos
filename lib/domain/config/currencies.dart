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

  static Currency fromCode(String code) {
    switch (code.toUpperCase()) {
      case 'USD':
        return Currency.usd;
      case 'ARS':
        return Currency.ars;
      case 'SAT':
      case 'BTC':
      default:
        return Currency.sat;
    }
  }
}

const List<Currency> currenciesList = [Currency.sat, Currency.usd, Currency.ars];
