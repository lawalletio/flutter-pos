import 'package:flutter/material.dart';

import '../../core/i18n.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/nostr/relay_list.dart';
import '../../data/nostr/relay_sync_service.dart';

/// Progress and log of the relay replication pass.
///
/// The log is the product here: replication writes to somebody else's
/// infrastructure, so an operator has to be able to see exactly what was sent
/// where, and what each relay said back.
class RelaySyncScreen extends StatelessWidget {
  const RelaySyncScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PosAppBar(title: context.tr('Relays'), showSync: false),
      body: ValueListenableBuilder<SyncReport>(
        valueListenable: relaySync.notifier,
        builder: (context, r, _) {
          if (r.phase == SyncPhase.idle && r.relays.isEmpty) {
            return PosBody(
              child: Center(
                child: Text(
                  context.tr('Todavía no se sincronizó ningún comercio.'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.muted, fontSize: 15),
                ),
              ),
            );
          }
          return PosBody(
            padding: EdgeInsets.zero,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                _summary(context, r),
                const SizedBox(height: 18),
                _sectionLabel(context.tr('RELAYS')),
                for (final e in r.relays) _relayRow(e),
                const SizedBox(height: 18),
                _sectionLabel(context.tr('REGISTRO')),
                if (r.log.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(context.tr('Sin actividad.'),
                        style: const TextStyle(
                            color: AppColors.muted, fontSize: 13)),
                  ),
                for (final l in r.log.reversed) _logRow(l),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _summary(BuildContext context, SyncReport r) {
    final running = r.isRunning;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (running)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  r.phase == SyncPhase.failed
                      ? Icons.error_outline
                      : Icons.check_circle_outline,
                  size: 18,
                  color: r.phase == SyncPhase.failed
                      ? AppColors.error
                      : AppColors.primary,
                ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  running
                      ? '${context.tr('Sincronizando')} ${r.relaysDone}/${r.relayCount}'
                      : context.tr('Sincronización completa'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          if (r.address != null) ...[
            const SizedBox(height: 6),
            Text(r.address!,
                style: const TextStyle(color: AppColors.muted, fontSize: 13)),
          ],
          if (!running && r.refused > 0) ...[
            const SizedBox(height: 8),
            Text(
              context.tr(
                  'Los rechazos son política del relay (eventos viejos, antispam). No se reintentan.'),
              style: const TextStyle(color: AppColors.muted, fontSize: 12),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              _stat(context.tr('Publicados'), '${r.published}'),
              _stat(context.tr('Rechazados'), '${r.refused}'),
              _stat(context.tr('Fallidos'), '${r.failed}'),
              _stat(context.tr('Al día'), '${r.alreadyInSync}'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          Text(label,
              style: const TextStyle(color: AppColors.muted, fontSize: 12)),
        ],
      );

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
              color: AppColors.muted,
              fontSize: 13,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w600),
        ),
      );

  Widget _relayRow(RelayEntry e) {
    final tags = <String>[
      if (e.source == RelaySource.merchant) 'comercio' else 'POS',
      if (e.read && e.write) 'r/w' else if (e.write) 'w' else 'r',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          const Icon(Icons.dns_outlined, size: 15, color: AppColors.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(e.url.replaceFirst('wss://', ''),
                style: const TextStyle(fontSize: 14)),
          ),
          Text(tags.join(' · '),
              style: const TextStyle(color: AppColors.muted, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _logRow(SyncLogEntry l) {
    final t = l.at;
    final stamp = '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(stamp,
              style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 11,
                  fontFeatures: [FontFeature.tabularFigures()])),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (l.relay.isNotEmpty)
                  Text(l.relay.replaceFirst('wss://', ''),
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 11)),
                Text(
                  l.message,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: l.isNote ? FontWeight.w600 : FontWeight.w400,
                    // Muted for a policy refusal, red only for a real failure.
                    color: l.refused
                        ? AppColors.muted
                        : (l.ok ? null : AppColors.error),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
