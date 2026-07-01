import 'package:flutter/foundation.dart';

/// The merchant Lightning Address currently in use. Set from Home and read by
/// the payment screen to generate real invoices from its callback.
final ValueNotifier<String> merchantAddress =
    ValueNotifier<String>('barra@lacrypta.ar');
