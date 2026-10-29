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
  'Sin sesión': 'No session',
  'Ingresar': 'Sign in',
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
  'Actualizar menú': 'Refresh menu',
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
  'Totales en propina': 'Tip totals',
  'Mostrar total en sats y ARS en cada opción':
      'Show the sats and ARS total on each option',
  'NO QUIERO DEJAR PROPINA': 'NO TIP',
  'Continuar': 'Continue',

  // Menu (misc)
  'Otros': 'Other',

  // Payment
  'Esperando el pago…': 'Waiting for payment…',
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
  'Seguir': 'Continue',
  'Error de impresión': 'Print error',
  'Impreso correctamente': 'Printed',
  'Buscando eventos…': 'Searching events…',
  'Zap e internos…': 'Zap and internal…',
  'Cobrando': 'Charging',
  'agregados': 'added',
  'Cobrando de la tarjeta…': 'Charging the card…',
  'Leyendo la tarjeta…': 'Reading the card…',
  'Solicitando el pago…': 'Requesting payment…',
  'Confirmando el pago…': 'Confirming payment…',
  'Enviando invoice': 'Sending invoice',
  'Cobrando con BoltCard': 'Charging with BoltCard',
  'Detectando pago…': 'Detecting payment…',
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

  // Invoice debug
  'Invoices generadas': 'Generated invoices',
  '¿Borrar el historial de invoices?': 'Clear the invoice history?',
  'Se borran solo las invoices de depuración. Las órdenes no se tocan.':
      'Only the debug invoices are erased. Orders are left as they are.',
  'Borrar': 'Clear',
  'Borrar historial': 'Clear history',
  'Cada respuesta del proveedor queda acá, aunque el QR haya pasado a otra.':
      'Every provider response is kept here, even if the QR moved on to another.',
  'Todavía no se generó ninguna invoice.': 'No invoice has been generated yet.',
  'invoices en este cobro': 'invoices for this charge',
  '1 invoice en este cobro': '1 invoice for this charge',
  'Respuesta vieja, ignorada': 'Stale reply, ignored',
  'Mostrada': 'Shown',
  'Pantalla cerrada': 'Screen closed',
  'Reemplazada': 'Replaced',
  'Dos pantallas de cobro': 'Two charge screens',
  'Orden': 'Order',
  'sin LUD-21': 'no LUD-21',
  'sin zap': 'no zap',
  'Pago confirmado': 'Payment confirmed',
  'Sin confirmar': 'Unconfirmed',
  'Copiar': 'Copy',
  'Verificar': 'Verify',
  'Apertura': 'Open',
  'Cupón': 'Coupon',
  'Reintento': 'Retry',

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
  'Sonido': 'Sound',
  'Activado': 'On',
  'Volumen general': 'General volume',
  'Volumen de toques': 'Touch volume',
  'Volumen de compra exitosa': 'Successful purchase volume',
  'Pago exitoso': 'Successful payment',
  'Se reproduce al confirmar el pago': 'Plays when a payment is confirmed',
  'Arpegio': 'Arpeggio',
  'Sapeee': 'Sapeee',
  'Impresora': 'Printer',
  'IMPRESORA': 'PRINTER',
  'Impresora ZCS SmartPos': 'ZCS SmartPos printer',
  'Probar impresora': 'Test printer',
  'Imprimiendo prueba…': 'Printing test…',
  'Imprimiendo…': 'Printing…',
  'relay': 'relay',
  'relays': 'relays',
  'Cupones': 'Coupons',
  'Modo kiosco': 'Kiosk mode',
  'punto': 'point',
  'puntos': 'points',
  'Elegí tu propina en sats': 'Pick your tip in sats',
  'Monto personalizado': 'Custom amount',
  'Falta configurar la dirección Lightning': 'Lightning address not set',
  'La dirección Lightning no soporta LUD-21': "The Lightning address doesn't support LUD-21",
  'Impresora no disponible': 'Printer not available',
  'Ingresá el PIN': 'Enter the PIN',
  'PIN incorrecto': 'Wrong PIN',
  'Salir': 'Exit',
  'Entrar': 'Enter',
  'Siguiente': 'Next',
  'Configuración de PIN': 'PIN settings',
  'Para desbloquear la pantalla': 'To unlock the screen',
  'SETEAR PIN': 'SET PIN',
  'CAMBIAR PIN': 'CHANGE PIN',
  'Nuevo PIN': 'New PIN',
  'Repetí el PIN': 'Repeat the PIN',
  'Entre 4 y 8 dígitos': '4 to 8 digits',
  'Los PIN no coinciden': "The PINs don't match",
  'PIN guardado': 'PIN saved',
  'Sin PIN: se desbloquea sin pedirlo.': 'No PIN: it unlocks without asking.',
  'Se desbloquea con tu PIN.': 'It unlocks with your PIN.',
  'Bloquear': 'Lock',
  'Desbloquear': 'Unlock',
  'Configurar rueda': 'Set up the wheel',
  'Rueda de la fortuna': 'Wheel of fortune',
  'Juego de premios': 'Prize game',
  'Activar y recuperar tarjetas': 'Activate and recover cards',
  'Premios': 'Prizes',
  'Personalizados': 'Custom',
  'Se editan en Configuración › Cupones': 'Edited in Settings › Coupons',
  'Imprimir ticket al ganar': 'Print the ticket on a win',
  'Duración de la ruleta': 'Wheel duration',
  'Aceleración': 'Acceleration',
  'Velocidad': 'Speed',
  'Mostrar la ruleta': 'Show the wheel',
  'Siempre': 'Always',
  'Solo con propina': 'Only with a tip',
  'Activar propina': 'Turn on tips',
  'Para mostrar la ruleta solo con propina, hay que activar la pantalla de propina.':
      'To show the wheel only with a tip, the tip screen has to be on.',
  'Activar': 'Turn on',
  'Si desactivás la propina, la ruleta deja de mostrarse. ¿Querés mostrarla siempre?':
      'If you turn tips off, the wheel stops appearing. Show it on every payment?',
  'No': 'No',
  'Tirar ruleta': 'Spin the wheel',
  'No hay premios': 'No prizes',
  'Ruleta': 'Wheel',
  'Girar': 'Spin',
  'Seguí participando': 'Keep playing',
  '¡Girá y ganá!': 'Spin and win!',
  'Deslizá fuerte o tocá dos veces': 'Swipe hard or double-tap',
  'Deslizá para girar otra vez': 'Swipe to spin again',
  '¡Más fuerte!': 'Harder!',
  'Girá más rápido para que cuente': 'Spin faster for it to count',
  'Imprimiendo tu ticket…': 'Printing your ticket…',
  'Tocá para continuar': 'Tap to continue',
  'Cupones de premio': 'Prize coupons',
  'CUPONES DE PREMIO': 'PRIZE COUPONS',
  'Imprimir cupones de premio después del cobro':
      'Print prize coupons after payment',
  'Modo de impresión': 'Print mode',
  'Automático': 'Automatic',
  'Botón': 'Button',
  'Premio': 'Prize',
  'premio': 'prize',
  'premios': 'prizes',
  'Probabilidad %': 'Chance %',
  'Editar premio': 'Edit prize',
  'Texto inválido': 'Invalid text',
  '¡Ganaste un premio!': 'You won a prize!',
  'Imprimir cupón': 'Print coupon',
  'Impreso': 'Printed',
  'Imprimiendo cupón…': 'Printing coupon…',

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
  'Los cupones de los productos dejan la orden en 0. No se puede cobrar.':
      "The products' coupons bring the order to 0. It can't be charged.",

  // Wapu
  'No sabemos si la orden se creó. Revisá el Historial antes de reintentar.':
      "We don't know if the order was created. Check the History before retrying.",
  'El servidor no respondió. Probá de nuevo.':
      'The server did not respond. Try again.',
  'La lightning address o el monto no son válidos':
      'The lightning address or the amount is not valid',
  'La API key no es válida': 'The API key is not valid',
  'Tu cuenta Wapu no tiene Beta features activado':
      'Your Wapu account does not have Beta features on',
  'Las compras están deshabilitadas en Wapu': 'Purchases are disabled in Wapu',
  'Tu cuenta Wapu no puede comprar': 'Your Wapu account cannot buy',
  'La orden no existe': 'The order does not exist',
  'No hay liquidez disponible ahora. Probá en unos minutos.':
      'No liquidity available right now. Try again in a few minutes.',
  'El monto está fuera de los límites': 'The amount is out of range',
  'Hay demasiadas órdenes abiertas. Esperá a que venzan.':
      'There are too many open orders. Wait for them to expire.',
  'Se alcanzó el límite mensual de compras':
      'The monthly purchase limit was reached',
  'Demasiados intentos. Esperá un momento.': 'Too many attempts. Wait a moment.',
  'El servicio no está disponible. Probá más tarde.':
      'The service is unavailable. Try again later.',
  'No se pudo completar la operación': 'The operation could not be completed',
  'Problema en la conexión. Intentando reconectar.':
      'Connection problem. Trying to reconnect.',
  'Configuración de Wapu': 'Wapu settings',
  'Avanzado': 'Advanced',
  'URL del backend': 'Backend URL',
  'Guardada: ': 'Saved: ',
  'Mostrar la API key': 'Show the API key',
  'Ocultar la API key': 'Hide the API key',
  'La URL tiene que empezar con https://': 'The URL must start with https://',
  'Olvidar key': 'Forget key',
  'Bitcoin sin KYC': 'Bitcoin without KYC',
  'Ingresá con la dirección del comercio para usar Wapu':
      'Sign in with the merchant address to use Wapu',
  'Configurá tu API key de Wapu': 'Set up your Wapu API key',
  'Desbloqueá el POS para configurar Wapu': 'Unlock the POS to set up Wapu',
  'Lightning address del cliente': "Customer's Lightning address",
  'nombre@dominio.com': 'name@domain.com',
  'Escanear QR': 'Scan QR',
  'Escaneá la lightning address del cliente':
      "Scan the customer's Lightning address",
  'Eso es un invoice. Pedile al cliente su lightning address':
      'That is an invoice. Ask the customer for their Lightning address',
  'Eso es un LNURL. Pedile al cliente su lightning address':
      'That is an LNURL. Ask the customer for their Lightning address',
  'La lightning address no es válida': 'The Lightning address is not valid',
  'No se pudo verificar la lightning address':
      'The Lightning address could not be verified',
  'El cliente recibe': 'The customer receives',
  'El cliente paga': 'The customer pays',
  'Tipo de cambio': 'Exchange rate',
  ' por BTC': ' per BTC',
  'Comisión incluida': 'Fee included',
  'Fee de red estimado': 'Estimated network fee',
  'El mínimo es ': 'The minimum is ',
  'Confirmar': 'Confirm',
  'Esperando la transferencia': 'Waiting for the transfer',
  'Alias': 'Alias',
  'Monto exacto': 'Exact amount',
  'Transferí exactamente este monto, con centavos':
      'Transfer exactly this amount, including the cents',
  'Vence en ': 'Expires in ',
  'Copiado': 'Copied',
  'Orden creada': 'Order created',
  'Pedir datos de transferencia': 'Request transfer details',
  'Venció el plazo': 'The time limit has passed',
  'Si el cliente ya transfirió, lo seguimos buscando hasta las ':
      'If the customer already transferred, we keep looking until ',
  'Orden vencida': 'Order expired',
  'Pago recibido. Enviando los sats…': 'Payment received. Sending the sats…',
  'En revisión': 'Under review',
  'Guardá el ID de la orden: ': 'Save the order ID: ',
  '¡Listo! El cliente recibió ': 'Done! The customer received ',
  'No se pudieron enviar los sats': 'The sats could not be sent',
  'El monto quedó en tu saldo de Wapu.':
      'The amount went to your Wapu balance.',
  'Nueva venta': 'New sale',
  'La orden queda abierta hasta que venza. La podés retomar desde el Historial.':
      'The order stays open until it expires. You can resume it from the History.',
  'Historial': 'History',
  'Todavía no hay órdenes': 'There are no orders yet',
  'En curso': 'In progress',
  'Completada': 'Completed',
  'Vencida': 'Expired',
  'En tu saldo': 'In your balance',
};
