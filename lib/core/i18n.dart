import 'package:flutter/widgets.dart';

/// Lightweight app localization.
///
/// Spanish is the *source* language: every UI string is written in Spanish and
/// looked up by that exact text. When the app language is English the string is
/// translated via [_en]; a missing entry falls back to the Spanish source, so
/// the app always renders (untranslated strings simply stay in Spanish).
///
/// Wired through Flutter's [Localizations] (see `AppLocalizationsDelegate`), so
/// switching the language in Settings rebuilds every screen automatically.

enum AppLanguage {
  es('es', 'Español'),
  en('en', 'English');

  const AppLanguage(this.code, this.label);
  final String code;
  final String label;

  static AppLanguage fromCode(String? code) => AppLanguage.values
      .firstWhere((l) => l.code == code, orElse: () => AppLanguage.es);
}

class AppLocalizations {
  AppLocalizations(this.language);
  final AppLanguage language;

  static AppLocalizations of(BuildContext context) =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      AppLocalizations(AppLanguage.es);

  /// Translate a Spanish source string to the active language.
  String tr(String es) {
    if (language == AppLanguage.es) return es;
    return _en[es] ?? es;
  }
}

extension AppLocalizationsX on BuildContext {
  /// Translate a Spanish source string, e.g. `context.tr('Cobrar')`.
  String tr(String es) => AppLocalizations.of(this).tr(es);

  /// The active app language.
  AppLanguage get lang => AppLocalizations.of(this).language;
}

class AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      AppLanguage.values.any((l) => l.code == locale.languageCode);

  @override
  Future<AppLocalizations> load(Locale locale) async =>
      AppLocalizations(AppLanguage.fromCode(locale.languageCode));

  @override
  bool shouldReload(AppLocalizationsDelegate old) => false;
}

/// Spanish → English, keyed by the exact Spanish source string.
/// Keep entries in sync with the `context.tr('…')` calls across the screens.
const Map<String, String> _en = {
  // Home
  'Ingresá la dirección Lightning del comercio': 'Enter the merchant Lightning address',
  'Configurar': 'Set up',
  'Ingresá una dirección': 'Enter an address',

  // Destination hub
  'MENÚ': 'MENU',
  'MODOS': 'MODES',
  'Caja registradora': 'Cash register',
  'Cobrar un monto manual': 'Charge a manual amount',
  'Órdenes': 'Orders',
  'Historial de la sesión': 'Session history',
  'Cuentas abiertas': 'Open tabs',
  'Tabs de clientes': 'Customer tabs',
  'Cambiar dirección': 'Change address',
  'Ingresar otra dirección': 'Enter another address',
  'Cerrar sesión': 'Log out',
  'Sin historial': 'No history',
  'Eliminar del historial': 'Remove from history',

  // Cash register / paydesk
  'Modo caja': 'Register mode',
  'Cobrar': 'Charge',

  // Relays / sync
  'Relays': 'Relays',
  'REGISTRO': 'LOG',
  'Sin actividad.': 'No activity.',
  'Sincronizando': 'Syncing',
  'Sincronización completa': 'Sync complete',
  'Publicados': 'Published',
  'Fallidos': 'Failed',
  'Al día': 'Up to date',
  'Rechazados': 'Refused',
  'Los rechazos son política del relay (eventos viejos, antispam). No se reintentan.':
      'Refusals are relay policy (old events, anti-spam). They are not retried.',
  'Todavía no se sincronizó ningún comercio.':
      'No merchant has been synced yet.',

  // Menu / cart
  'Ver carrito': 'View cart',
  'Resumen de compra': 'Order summary',
  'Menú': 'Menu',
  'Esperando cotización…': 'Waiting for rate…',
  'Sin conexión': 'Offline',
  'actualizado': 'updated',
  'recién': 'just now',
  'producto oculto (precio no soportado)': 'product hidden (unsupported price)',
  'productos ocultos (precio no soportado)':
      'products hidden (unsupported price)',
  'Este comercio todavía no publicó su menú':
      'This merchant has not published a menu yet',
  'No se pudo leer el catálogo': 'Could not read the catalog',
  'Podés cobrar un monto manual desde la caja.':
      'You can charge a manual amount from the register.',
  'unidad': 'unit',
  'unidades': 'units',

  // Tip
  'Propina': 'Tip',
  '¿Cuánto dejás de propina?': 'How much would you like to tip?',
  'Total sin propina': 'Total without tip',
  'NO QUIERO DEJAR PROPINA': 'NO TIP',
  'Continuar': 'Continue',

  // Menu (misc)
  'Otros': 'Other',

  // Payment
  'Esperando el pago…': 'Waiting for payment…',
  'Copiar invoice': 'Copy invoice',
  'Invoice copiada': 'Invoice copied',
  'Acercá la tarjeta para pagar': 'Tap the card to pay',
  'Cancelar': 'Cancel',
  'Agregar a tab': 'Add to tab',
  'Check event': 'Check event',
  'Generando invoice…': 'Generating invoice…',
  'Resolviendo la Lightning Address…': 'Resolving the Lightning address…',
  'No se pudo generar la invoice.': 'Could not generate the invoice.',
  'La orden no tiene monto.': 'The order has no amount.',
  'Volver': 'Back',
  'Reintentar': 'Retry',
  'Buscando eventos…': 'Searching events…',
  'Zap e internos…': 'Zap and internal…',
  'Cobrando': 'Charging',
  'agregados': 'added',
  'Cobrando de la tarjeta…': 'Charging the card…',
  'Leyendo la tarjeta…': 'Reading the card…',
  'Solicitando el pago…': 'Requesting payment…',
  'Confirmando el pago…': 'Confirming payment…',
  'No retires la tarjeta': 'Do not remove the card',
  'Pago enviado, esperando confirmación…': 'Payment sent, awaiting confirmation…',
  '¡Pago acreditado!': 'Payment received!',
  'Gracias por su pago': 'Thank you for your payment',
  'Agregado a la cuenta': 'Added to the tab',
  'Total de la cuenta': 'Tab total',
  'Agregar a una cuenta': 'Add to a tab',
  'CUENTAS ABIERTAS': 'OPEN TABS',
  'o crear una nueva': 'or create a new one',
  'Nombre del nuevo cliente': 'New customer name',
  'Crear cuenta nueva': 'Create new tab',

  // Tabs
  'No hay cuentas abiertas.': 'No open tabs.',
  'Borrar todo': 'Delete all',
  '¿Borrar todas las cuentas?': 'Delete all tabs?',
  'Esta acción no se puede deshacer.': 'This action cannot be undone.',

  // Orders
  'Total vendido': 'Total sold',
  'venta': 'sale',
  'ventas': 'sales',
  'Eliminar todas': 'Delete all',
  '¿Eliminar todas las órdenes?': 'Delete all orders?',
  'Se borrará el historial de órdenes de esta sesión. Esta acción no se puede deshacer.':
      'This session\'s order history will be erased. This action cannot be undone.',
  'Todavía no hay órdenes creadas.': 'No orders created yet.',
  'ID copiado': 'ID copied',
  'Acreditado': 'Received',
  'Pendiente': 'Pending',
  'Cobro manual': 'Manual charge',
  'Reverificar': 'Re-check',
  'Checkear': 'Check',
  // Recheck modal
  'Reverificando pago…': 'Re-checking payment…',
  'Verificando pago (LUD-21)…': 'Verifying payment (LUD-21)…',
  'Verificando zap Nostr (NIP-57)…': 'Verifying Nostr zap (NIP-57)…',
  '¡Pago confirmado!': 'Payment confirmed!',
  'Todavía sin confirmar': 'Still unconfirmed',
  'Cerrar': 'Close',

  // Settings
  'Configuración': 'Settings',
  'Cuenta': 'Account',
  'General': 'General',
  'Idioma': 'Language',
  'Mostrar pantalla de propina antes de cobrar': 'Show a tip screen before charging',
  'Cuentas (tabs)': 'Tabs',
  'Llevar cuenta por cliente': 'Keep a tab per customer',
  'RELAYS NOSTR': 'NOSTR RELAYS',
  'Relays Nostr': 'Nostr relays',
  'Agregar relay': 'Add relay',
  'Agregar': 'Add',
  'Editar relay': 'Edit relay',
  'Guardar': 'Save',
  'Restablecer': 'Reset',
  'Sugeridos': 'Suggested',
  'URL inválida o repetida': 'Invalid or duplicate URL',
  'Impresora': 'Printer',
  'IMPRESORA': 'PRINTER',
  'Impresora ZCS SmartPos': 'ZCS SmartPos printer',
  'Probar impresora': 'Test printer',
  'Imprimiendo prueba…': 'Printing test…',
  'relay': 'relay',
  'relays': 'relays',

  // Coupons
  'Escanear cupón': 'Scan coupon',
  'Cupón aplicado': 'Coupon applied',
  'Apuntá al QR del cupón': 'Point at the coupon QR',
  'Ese QR no es un cupón': "That QR isn't a coupon",
  'No pudimos aplicar el cupón': "We couldn't apply the coupon",
  'Con este cupón el total queda por debajo del mínimo de':
      'With this coupon the total falls below the minimum of',
  '¿Quitar el cupón?': 'Remove the coupon?',
  'Se cobra el precio completo. El cupón ya fue canjeado y no se puede volver a usar.':
      'The full price will be charged. The coupon has already been redeemed and cannot be reused.',
  'Quitar': 'Remove',
  'Quitar cupón': 'Remove coupon',
  'Descuento': 'Discount',
  'Subtotal': 'Subtotal',
  'Total': 'Total',
  'Ingresar el código': 'Enter the code',
  'Código del cupón': 'Coupon code',
  'Pegá o escribí el código': 'Paste or type the code',
  'Pegar': 'Paste',
  'Ese código no es un cupón': "That code isn't a coupon",
  'Aplicar': 'Apply',
};
