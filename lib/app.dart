import 'package:flutter/material.dart';

import 'core/router.dart';
import 'core/theme.dart';

/// Root app. Routing via go_router; screens under `features/`.
/// UI/UX preview build — payment engine + native channels wire in later milestones.
class LaWalletPosApp extends StatelessWidget {
  const LaWalletPosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'LaWallet POS',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      routerConfig: appRouter,
    );
  }
}
