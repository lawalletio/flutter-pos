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
  Size get preferredSize => const Size.fromHeight(72);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: AppColors.background,
      elevation: 0,
      toolbarHeight: 72,
      leadingWidth: 68,
      leading: showBack
          ? Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Material(
                color: AppColors.surface,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () =>
                      context.canPop() ? context.pop() : context.go('/hub'),
                  child: const SizedBox(
                    width: 48,
                    height: 48,
                    child: Icon(Icons.arrow_back, size: 26),
                  ),
                ),
              ),
            )
          : null,
      title: title == null
          ? null
          : Text(title!,
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
      actions: [
        if (showSettings)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton(
              icon: const Icon(Icons.settings_outlined, size: 26),
              onPressed: () => context.push('/settings'),
            ),
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
          padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 20),
          child: Row(
            children: [
              Icon(icon, size: 34, color: AppColors.primary),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w600)),
                    if (sublabel != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(sublabel!,
                            style: const TextStyle(
                                fontSize: 14, color: AppColors.muted)),
                      ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 26, color: AppColors.muted),
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
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}
