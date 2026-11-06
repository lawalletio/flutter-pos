import 'package:flutter/material.dart';

import '../../core/i18n.dart';
import '../../core/theme.dart';
import 'wapu_api.dart';

/// A failed Wapu call, for the operator: the translated copy that
/// [wapuErrorKey] picks for [error], and under it the backend's own message as
/// a small muted detail line. Set [creating] for an order create, which has its
/// own copy when the outcome is unknown.
///
/// Both lines are Material [Text]. This file does not import the app's
/// `core/ui.dart`, whose `Text` uppercases and squeezes into one line, which
/// would mangle a backend message.
class WapuErrorText extends StatelessWidget {
  const WapuErrorText(this.error, {super.key, this.creating = false});

  final WapuApiException error;
  final bool creating;

  @override
  Widget build(BuildContext context) {
    final detail = error.message.trim();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          context.tr(wapuErrorKey(error, creating: creating)),
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.error),
        ),
        // 'timeout' is the API's own word for a timeout, which the copy says.
        if (detail.isNotEmpty && detail != 'timeout')
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              detail,
              key: const Key('wapu-error-detail'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted, fontSize: 13),
            ),
          ),
      ],
    );
  }
}
