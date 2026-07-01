import 'package:flutter/material.dart';

import 'theme.dart';

/// POS numpad. Emits digit strings ('0'–'9') and a backspace signal.
class Numpad extends StatelessWidget {
  final void Function(String digit) onDigit;
  final VoidCallback onBackspace;
  const Numpad({super.key, required this.onDigit, required this.onBackspace});

  @override
  Widget build(BuildContext context) {
    final keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '00', '0', '⌫'];
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 1.7,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: keys.map((k) {
        if (k.isEmpty) return const SizedBox.shrink();
        final isBack = k == '⌫';
        return Material(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => isBack ? onBackspace() : onDigit(k),
            child: Center(
              child: isBack
                  ? const Icon(Icons.backspace_outlined, size: 24)
                  : Text(k,
                      style: const TextStyle(
                          fontSize: 26, fontWeight: FontWeight.w600)),
            ),
          ),
        );
      }).toList(),
    );
  }
}
