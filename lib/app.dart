import 'package:flutter/material.dart';

import 'core/theme.dart';

/// Root app widget. Routing (go_router) and the feature screens are added in M4;
/// this M0 shell just proves the theme + entry point compile.
class LaWalletPosApp extends StatelessWidget {
  const LaWalletPosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LaWallet POS',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const _M0Placeholder(),
    );
  }
}

class _M0Placeholder extends StatelessWidget {
  const _M0Placeholder();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('LaWallet POS', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 8),
            const Text('M0 scaffold — see docs/'),
          ],
        ),
      ),
    );
  }
}
