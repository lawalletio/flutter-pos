import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../../domain/order/product.dart';

/// Static/mock data used to exercise the UI/UX before the payment engine is wired.
/// Menus load from the same asset JSON the production app will ship.

Future<Map<int, String>> loadCategories() async {
  final raw = await rootBundle.loadString('assets/categories.json');
  final list = jsonDecode(raw) as List;
  final map = <int, String>{};
  for (final c in list) {
    map[(c['id'] as num).toInt()] = c['name'] as String;
  }
  return map;
}

Future<List<Product>> loadMenu(String name) async {
  final raw = await rootBundle.loadString('assets/menus/$name.json');
  final list = jsonDecode(raw) as List;
  return list
      .map((e) => Product.fromJson(e as Map<String, dynamic>))
      .toList();
}

/// Venues surfaced on the destination hub (mirrors the webapp mapping).
const List<({String menu, String title})> kVenues = [
  (menu: 'barra', title: 'Barra'),
  (menu: 'comida', title: 'Comida'),
  (menu: 'cafe', title: 'Café'),
  (menu: 'bitnaria', title: 'Bitnaria'),
  (menu: 'merch', title: 'Merch'),
  (menu: 'test', title: 'Test'),
];

/// Mock order history for the Orders screen.
class MockOrder {
  final String id;
  final int amountSats;
  final DateTime createdAt;
  final bool isPaid;
  final String summary;
  const MockOrder(this.id, this.amountSats, this.createdAt, this.isPaid, this.summary);
}

final List<MockOrder> kMockOrders = [
  MockOrder('a1b2c3d4e5f6', 21000, DateTime(2026, 6, 30, 21, 14), true, '2x Coca, 1x Empanada'),
  MockOrder('f6e5d4c3b2a1', 8500, DateTime(2026, 6, 30, 20, 51), true, '1x Café'),
  MockOrder('998877665544', 45000, DateTime(2026, 6, 30, 20, 3), false, '1x Remera'),
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
