import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'theme.dart';

/// Shared UI building blocks for the POS screens.

/// Top app bar with an optional back button and a settings gear (mirrors the
/// webapp's `layout/top.tsx` + `Navbar`).
class PosAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String? title;
  final bool showBack;
  final bool showSettings;
  const PosAppBar({super.key, this.title, this.showBack = true, this.showSettings = true});

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: AppColors.background,
      elevation: 0,
      toolbarHeight: 64,
      leading: showBack
          ? IconButton(
              icon: const Icon(Icons.arrow_back_ios_new, size: 20),
              onPressed: () => context.canPop() ? context.pop() : context.go('/hub'),
            )
          : null,
      title: title == null
          ? null
          : Text(title!, style: const TextStyle(fontWeight: FontWeight.w700)),
      actions: [
        if (showSettings)
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/settings'),
          ),
      ],
    );
  }
}

/// Large tappable card used on the hub for venues and modes.
class PosCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? sublabel;
  final Color? color;
  final VoidCallback onTap;
  const PosCard({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.sublabel,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.surface;
    return Material(
      color: c,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 18),
          child: Row(
            children: [
              Icon(icon, size: 28, color: AppColors.primary),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w600)),
                    if (sublabel != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(sublabel!,
                            style: const TextStyle(
                                fontSize: 13, color: AppColors.muted)),
                      ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.muted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Centered content column with a max width (POS runs portrait/narrow).
class PosBody extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const PosBody({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}
