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

/// A fast, smooth transition applied to every route change: the incoming page
/// fades in while easing up from a slight scale/offset — snappy enough for a POS
/// yet polished.
Page<void> _page(Widget child) => CustomTransitionPage<void>(
      child: child,
      transitionDuration: const Duration(milliseconds: 240),
      reverseTransitionDuration: const Duration(milliseconds: 190),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.97, end: 1.0).animate(curved),
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.015),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          ),
        );
      },
    );

final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', pageBuilder: (c, s) => _page(const HomeScreen())),
    GoRoute(
      path: '/hub',
      pageBuilder: (c, s) => _page(
        HubScreen(
          address: s.uri.queryParameters['address'] ?? 'barra@lacrypta.ar',
          openMenu: s.uri.queryParameters['menu'] == '1',
        ),
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
