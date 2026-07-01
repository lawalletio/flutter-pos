import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../../domain/order/product.dart';

/// Static/mock data used to exercise the UI/UX before the payment engine is wired.
/// Menus load from the same asset JSON the production app will ship.

/// Categories in their canonical file order (used to order menu sections).
Future<List<({int id, String name})>> loadCategories() async {
  final raw = await rootBundle.loadString('assets/categories.json');
  final list = jsonDecode(raw) as List;
  return [
    for (final c in list)
      (id: (c['id'] as num).toInt(), name: c['name'] as String),
  ];
}

Future<List<Product>> loadMenu(String name) async {
  final raw = await rootBundle.loadString('assets/menus/$name.json');
  final list = jsonDecode(raw) as List;
  return list
      .map((e) => Product.fromJson(e as Map<String, dynamic>))
      .toList();
}

/// Venues known to the POS (mirrors the webapp's `[destination]/page.tsx` mapping).
const List<({String menu, String title})> kVenues = [
  (menu: 'barra', title: 'Barra'),
  (menu: 'comida', title: 'Comida'),
  (menu: 'cafe', title: 'Café'),
  (menu: 'bitnaria', title: 'Bitnaria'),
  (menu: 'merch', title: 'Merch'),
  (menu: 'test', title: 'Test'),
];

/// Resolve the single venue menu for a Lightning Address, matched by the username
/// part (e.g. `merch@lacrypta.ar` → Merch). Returns null if the address does not
/// map to a known venue — matching the webapp, where only the matching menu card
/// is shown (and none if there's no match).
({String menu, String title})? venueForAddress(String address) {
  final user = address.trim().toLowerCase().split('@').first;
  for (final v in kVenues) {
    if (v.menu == user) return v;
  }
  return null;
}

/// Mock order history for the Orders screen.
class MockOrder {
  final String id;
  final int amountSats;
  final DateTime createdAt;
  final bool isPaid;
  final String summary;
  final String publishStatus; // Pendiente | Publicada | Fallida
  final int publishRelays;
  final String zapStatus; // Pendiente | Confirmado
  final int zapRelays;
  const MockOrder(
    this.id,
    this.amountSats,
    this.createdAt,
    this.isPaid,
    this.summary, {
    this.publishStatus = 'Publicada',
    this.publishRelays = 3,
    this.zapStatus = 'Pendiente',
    this.zapRelays = 0,
  });
}

final List<MockOrder> kMockOrders = [
  MockOrder('a1b2c3d4e5f6', 21000, DateTime(2026, 6, 30, 21, 14), true,
      '2x Coca, 1x Empanada',
      publishStatus: 'Publicada', publishRelays: 3, zapStatus: 'Confirmado', zapRelays: 2),
  MockOrder('f6e5d4c3b2a1', 8500, DateTime(2026, 6, 30, 20, 51), true, '1x Café',
      publishStatus: 'Publicada', publishRelays: 2, zapStatus: 'Confirmado', zapRelays: 2),
  MockOrder('998877665544', 45000, DateTime(2026, 6, 30, 20, 3), false,
      '1x Remera',
      publishStatus: 'Publicada', publishRelays: 3, zapStatus: 'Pendiente', zapRelays: 0),
];

/// Mock open tabs for the Tab screen.
class MockTab {
  final String id;
  final String name;
  final int amountSats;
  final String summary;
  const MockTab(this.id, this.name, this.amountSats, this.summary);
}

final List<MockTab> kMockTabs = [
  MockTab('t1', 'Mesa 4', 63000, '3x Cerveza, 2x Empanada'),
  MockTab('t2', 'Juan', 21000, '1x Fernet'),
];
