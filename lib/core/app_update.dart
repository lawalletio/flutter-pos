import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'i18n.dart';
import 'theme.dart';
import 'ui.dart';

/// Self-update from the GitHub releases (Android sideloads only; Play installs
/// and iOS update through their store).
const _latestRelease =
    'https://api.github.com/repos/lawalletio/flutter-pos/releases/latest';
const MethodChannel _ch = MethodChannel('pos/update');
@visibleForTesting
Dio updateDio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 15)));

class AppUpdate {
  const AppUpdate(this.version, this.apkUrl, this.notes);
  final String version;
  final String apkUrl;
  final String notes;
}

/// True when [latest] (e.g. `v0.5.0`) is a higher x.y.z than [current].
bool isNewerVersion(String latest, String current) {
  List<int> parts(String v) => v
      .replaceFirst(RegExp(r'^v'), '')
      .split(RegExp(r'[.+-]'))
      .take(3)
      .map((p) => int.tryParse(p) ?? 0)
      .toList();
  final a = parts(latest), b = parts(current);
  for (var i = 0; i < 3; i++) {
    final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

/// The APK built for [abi] (`…-armeabi-v7a.apk`), else the universal one.
/// Splits carry a higher versionCode than the universal APK, so a device on a
/// split must stay on splits or the install is rejected as a downgrade.
String? pickApk(List<String> urls, String abi) {
  final apks = urls.where((u) => u.endsWith('.apk')).toList();
  for (final u in apks) {
    if (u.endsWith('-$abi.apk')) return u;
  }
  const abis = ['arm64-v8a', 'armeabi-v7a', 'x86_64', 'x86'];
  for (final u in apks) {
    if (!abis.any((a) => u.endsWith('-$a.apk'))) return u;
  }
  return null;
}

/// Native facts: device ABI, where to save the APK, and whether Play
/// installed us (then Play owns updates).
Future<Map<String, dynamic>?> _info() async {
  if (defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    return await _ch.invokeMapMethod<String, dynamic>('info');
  } on MissingPluginException {
    return null;
  }
}

/// The latest release when it's newer than this build; null otherwise.
/// Throws on network errors (callers that don't care just catch).
Future<AppUpdate?> checkForUpdate() async {
  final info = await _info();
  if (info == null || info['fromStore'] == true) return null;
  final res = await updateDio.get<Map<String, dynamic>>(_latestRelease);
  final release = res.data!;
  final tag = release['tag_name'] as String;
  final current = (await PackageInfo.fromPlatform()).version;
  if (!isNewerVersion(tag, current)) return null;
  final urls = [
    for (final a in release['assets'] as List)
      (a as Map)['browser_download_url'] as String
  ];
  final apk = pickApk(urls, info['abi'] as String);
  if (apk == null) return null;
  // Plain text: drop markdown headings, bold and code ticks.
  final notes = ((release['body'] as String?) ?? '')
      .replaceAll(RegExp(r'^#+\s*', multiLine: true), '')
      .replaceAll(RegExp(r'\*\*|`'), '');
  return AppUpdate(tag, apk, notes);
}

/// Whether this build can self-update (drives the Settings button).
Future<bool> canSelfUpdate() async {
  final info = await _info();
  return info != null && info['fromStore'] != true;
}

/// Downloads the APK (reporting 0..1) and hands it to the system installer.
Future<void> _downloadAndInstall(
    AppUpdate update, void Function(double) onProgress) async {
  final info = (await _info())!;
  final path = '${info['dir']}/lawallet-pos-update.apk';
  await updateDio.download(update.apkUrl, path,
      onReceiveProgress: (got, total) {
    if (total > 0) onProgress(got / total);
  });
  await _ch.invokeMethod('install', {'path': path});
}

/// Silent startup check: asks only when there is something to install.
Future<void> autoCheckForUpdate(BuildContext Function() context) async {
  try {
    final update = await checkForUpdate();
    if (update == null) return;
    final ctx = context();
    if (ctx.mounted) await showUpdateDialog(ctx, update);
  } catch (e) {
    debugPrint('update check: $e');
  }
}

Future<void> showUpdateDialog(BuildContext context, AppUpdate update) =>
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UpdateDialog(update),
    );

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog(this.update);
  final AppUpdate update;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double? _progress; // null = not started
  String? _error;

  Future<void> _start() async {
    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      await _downloadAndInstall(
          widget.update, (p) => mounted ? setState(() => _progress = p) : null);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _progress = null;
          _error = e is DioException ? (e.message ?? '$e') : '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final downloading = _progress != null;
    return PopScope(
      canPop: !downloading,
      child: AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('${context.tr('Nueva versión')} ${widget.update.version}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (downloading) ...[
                Text(context.tr('Descargando…')),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: _progress, minHeight: 8),
                const SizedBox(height: 8),
                Text('${(_progress! * 100).toStringAsFixed(0)}%',
                    textAlign: TextAlign.end),
              ] else if (widget.update.notes.trim().isNotEmpty)
                Text(widget.update.notes.trim(), softWrap: true),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                    softWrap: true,
                    style: const TextStyle(color: Colors.redAccent)),
              ],
            ],
          ),
        ),
        actions: downloading
            ? null
            : [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(context.tr('Más tarde'),
                      style: const TextStyle(color: AppColors.muted)),
                ),
                FilledButton(
                  onPressed: _start,
                  child: Text(
                      context.tr(_error == null ? 'Actualizar' : 'Reintentar')),
                ),
              ],
      ),
    );
  }
}

/// Small full-width "check for updates" (Android sideloads only).
class CheckUpdatesButton extends StatefulWidget {
  const CheckUpdatesButton({super.key});

  @override
  State<CheckUpdatesButton> createState() => _CheckUpdatesButtonState();
}

class _CheckUpdatesButtonState extends State<CheckUpdatesButton> {
  final Future<bool> _supported = canSelfUpdate();
  bool _checking = false;

  Future<void> _check() async {
    setState(() => _checking = true);
    final messenger = ScaffoldMessenger.of(context);
    String? message;
    try {
      final update = await checkForUpdate();
      if (!mounted) return;
      if (update != null) {
        await showUpdateDialog(context, update);
      } else {
        message = context.tr('Ya tenés la última versión');
      }
    } catch (_) {
      if (mounted) message = context.tr('No se pudo buscar actualizaciones');
    }
    if (!mounted) return;
    setState(() => _checking = false);
    if (message != null) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _supported,
      builder: (context, snap) => snap.data != true
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
              child: SizedBox(
                width: double.infinity,
                height: 40,
                child: OutlinedButton.icon(
                  onPressed: _checking ? null : _check,
                  icon: _checking
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.system_update_rounded, size: 18),
                  label: Text(context.tr('Buscar actualizaciones'),
                      style: const TextStyle(fontSize: 13)),
                ),
              ),
            ),
    );
  }
}
