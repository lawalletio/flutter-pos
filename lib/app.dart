import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/i18n.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'domain/config/settings_state.dart';

/// Root app. Routing via go_router; screens under `features/`.
/// The app language is driven by [appSettings]; changing it in Settings updates
/// [MaterialApp.locale], which re-localizes every screen via [Localizations].
class LaWalletPosApp extends StatelessWidget {
  const LaWalletPosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SettingsState>(
      valueListenable: appSettings,
      builder: (context, s, _) => MaterialApp.router(
        title: 'LaWallet POS',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        routerConfig: appRouter,
        locale: Locale(AppLanguage.fromCode(s.languageCode).code),
        supportedLocales:
            AppLanguage.values.map((l) => Locale(l.code)).toList(),
        localizationsDelegates: const [
          AppLocalizationsDelegate(),
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
      ),
    );
  }
}
