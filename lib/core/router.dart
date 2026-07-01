import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../features/home/home_screen.dart';
import '../features/destination/hub_screen.dart';
import '../features/cart/menu_screen.dart';
import '../features/paydesk/paydesk_screen.dart';
import '../features/tip/tip_screen.dart';
import '../features/payment/payment_screen.dart';
import '../features/orders/orders_screen.dart';
import '../features/tab/tab_screen.dart';
import '../features/settings/settings_screen.dart';

/// Instant (no slide) transitions — snappier for a POS and stable for headless
/// screenshots.
Page<void> _page(Widget child) => NoTransitionPage(child: child);

final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', pageBuilder: (c, s) => _page(const HomeScreen())),
    GoRoute(
      path: '/hub',
      pageBuilder: (c, s) => _page(
        HubScreen(address: s.uri.queryParameters['address'] ?? 'barra@lacrypta.ar'),
      ),
    ),
    GoRoute(
      path: '/cart/:menu',
      pageBuilder: (c, s) => _page(MenuScreen(
        menu: s.pathParameters['menu']!,
        demo: s.uri.queryParameters['demo'] == '1',
      )),
    ),
    GoRoute(path: '/paydesk', pageBuilder: (c, s) => _page(const PaydeskScreen())),
    GoRoute(
      path: '/tip',
      pageBuilder: (c, s) {
        final sats = int.tryParse(s.uri.queryParameters['sats'] ?? '') ?? 0;
        return _page(TipScreen(amountSats: sats, back: s.uri.queryParameters['back']));
      },
    ),
    GoRoute(
      path: '/payment',
      pageBuilder: (c, s) {
        final sats = int.tryParse(s.uri.queryParameters['sats'] ?? '') ?? 0;
        final paid = s.uri.queryParameters['paid'] == '1';
        return _page(PaymentScreen(
          amountSats: sats,
          initiallyPaid: paid,
          openAddTab: s.uri.queryParameters['addtab'] == '1',
          back: s.uri.queryParameters['back'],
        ));
      },
    ),
    GoRoute(path: '/orders', pageBuilder: (c, s) => _page(const OrdersScreen())),
    GoRoute(path: '/tab', pageBuilder: (c, s) => _page(const TabScreen())),
    GoRoute(path: '/settings', pageBuilder: (c, s) => _page(const SettingsScreen())),
  ],
);
