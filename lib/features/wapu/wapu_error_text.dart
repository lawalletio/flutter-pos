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

/// A call that got no answer from the backend (so [WapuApiException] has no
/// status code), on a screen that tries it again by itself. It reads as a muted
/// line that says so, not as a red error. A tap opens it onto the
/// [WapuErrorText] of [error], and another closes it. It stays open while a
/// newer failure takes the place of the one it shows.
class WapuReconnecting extends StatefulWidget {
  const WapuReconnecting(this.error, {super.key});

  final WapuApiException error;

  @override
  State<WapuReconnecting> createState() => _WapuReconnectingState();
}

class _WapuReconnectingState extends State<WapuReconnecting> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const Key('wapu-reconnecting'),
      onTap: () => setState(() => _open = !_open),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.wifi_off, size: 18, color: AppColors.muted),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    context
                        .tr('Problema en la conexión. Intentando reconectar.'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.muted),
                  ),
                ),
              ],
            ),
            if (_open)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: WapuErrorText(widget.error),
              ),
          ],
        ),
      ),
    );
  }
}
