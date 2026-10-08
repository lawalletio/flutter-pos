import 'i18n.dart';
import 'theme.dart';
import '../platform/printer_channel.dart';
import 'ui.dart';

enum _PrintErrorAction { retry, proceed }

/// Prints, and on failure holds the next screen until the cashier retries or
/// chooses to continue without a ticket.
///
/// Returns true when a print succeeded. Returns false when the cashier chose
/// to continue past the error, which is the signal to take the step that was
/// waiting.
Future<bool> printOrAskToContinue(
  BuildContext context, {
  required Future<PrintResult> Function() print,
}) async {
  while (context.mounted) {
    final result = await print();
    if (!context.mounted) return false;
    if (result.ok) return true;
    final action = await showDialog<_PrintErrorAction>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text(ctx.tr('Error de impresión')),
          content: Text(result.message, softWrap: true),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(_PrintErrorAction.proceed),
              child: Text(ctx.tr('Seguir'),
                  style: const TextStyle(color: AppColors.muted)),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(_PrintErrorAction.retry),
              child: Text(ctx.tr('Reintentar')),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return false;
    if (action == _PrintErrorAction.proceed) return false;
  }
  return false;
}
