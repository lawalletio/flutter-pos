// Mock data still used by the preview screens (tabs).
//
// The menu no longer lives here: it comes from the merchant's own NIP-99
// catalog on nostr (see `data/nostr/catalog_service.dart`). The bundled
// `assets/menus/*.json` and the `kVenues` address→menu mapping were removed
// with it — a hardcoded price is a build artifact, and there is no safe moment
// to charge one.

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
