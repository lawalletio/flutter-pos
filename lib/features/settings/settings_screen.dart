import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/i18n.dart';
import '../../core/sounds.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../domain/config/session.dart';
import '../../domain/config/settings_persistence.dart';
import '../../domain/config/settings_state.dart';
import '../../domain/order/order_reset.dart';
import '../../domain/prize/prize_wheel.dart';
import '../../platform/printer_channel.dart';

/// Loaded once and reused across rebuilds.
final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

/// Shown immediately (and as a fallback if package_info isn't available on this
/// platform). Keep in sync with `pubspec.yaml`.
const String kFallbackVersion = '0.1.0';

/// One settings area. [path] is the route under `/settings`.
enum SettingsSection {
  account('cuenta', 'Cuenta', Icons.storefront_outlined),
  general('general', 'General', Icons.tune_rounded),
  sound('sonido', 'Sonido', Icons.volume_up_outlined),
  relays('relays', 'Relays', Icons.podcasts_rounded),
  printer('impresora', 'Impresora', Icons.print_outlined),
  coupons('cupones', 'Cupones', Icons.local_activity_outlined);

  const SettingsSection(this.path, this.titleKey, this.icon);

  final String path;
  final String titleKey;
  final IconData icon;
}

/// Settings home: six large tiles. Each one opens its own section.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PosAppBar(title: context.tr('Configuración'), showSettings: false),
      bottomNavigationBar: const _VersionFooter(),
      body: PosBody(
        child: GridView.count(
          crossAxisCount: 2,
          mainAxisSpacing: 14,
          crossAxisSpacing: 14,
          childAspectRatio: 1,
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            for (final section in SettingsSection.values)
              _SettingsTile(section: section),
          ],
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({required this.section});

  final SettingsSection section;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: () => context.push('/settings/${section.path}'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(section.icon, size: 40, color: AppColors.primary),
              ),
              const SizedBox(height: 16),
              Text(
                context.tr(section.titleKey),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A single settings area, pushed from the tile grid.
class SettingsSectionScreen extends StatelessWidget {
  const SettingsSectionScreen({super.key, required this.section});

  final SettingsSection section;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PosAppBar(
        title: context.tr(section.titleKey),
        showSettings: false,
      ),
      body: ValueListenableBuilder<SettingsState>(
        valueListenable: appSettings,
        builder: (context, s, _) => PosBody(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: _sectionBody(context, s),
          ),
        ),
      ),
    );
  }

  List<Widget> _sectionBody(BuildContext context, SettingsState s) {
    switch (section) {
      case SettingsSection.account:
        return [
          _card(Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.storefront_outlined,
                        size: 20, color: AppColors.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(merchantAddress.value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15)),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              InkWell(
                onTap: () {
                  resetOrder();
                  context.go('/');
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Row(
                    children: [
                      const Icon(Icons.logout, size: 20, color: AppColors.error),
                      const SizedBox(width: 10),
                      Text(context.tr('Cerrar sesión'),
                          style: const TextStyle(
                              color: AppColors.error,
                              fontSize: 15,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ],
          )),
        ];
      case SettingsSection.general:
        return [
          _card(Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: _LanguageSelector(current: s.languageCode),
              ),
              const Divider(height: 1),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                activeTrackColor: AppColors.primary,
                title: Text(context.tr('Propina')),
                subtitle: Text(
                    context.tr('Mostrar pantalla de propina antes de cobrar'),
                    style: const TextStyle(color: AppColors.muted, fontSize: 12)),
                value: s.tipEnabled,
                onChanged: (enabled) =>
                    _onTipChanged(context, enabled, s.wheelOffer),
              ),
              const Divider(height: 1),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                activeTrackColor: AppColors.primary,
                title: Text(context.tr('Cuentas (tabs)')),
                subtitle: Text(context.tr('Llevar cuenta por cliente'),
                    style: const TextStyle(color: AppColors.muted, fontSize: 12)),
                value: s.tabEnabled,
                onChanged: setTabEnabled,
              ),
            ],
          )),
        ];
      case SettingsSection.sound:
        return [
          _card(Column(
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                activeTrackColor: AppColors.primary,
                title: Text(context.tr('Activado')),
                value: s.soundEnabled,
                onChanged: setSoundEnabled,
              ),
              const Divider(height: 1),
              _VolumeSlider(
                label: context.tr('Volumen general'),
                value: s.soundVolume,
                enabled: s.soundEnabled,
                onChanged: (v) => setSoundVolume(v, persist: false),
                onChangeEnd: (v) {
                  setSoundVolume(v);
                  AppSounds.play(AppSound.invoice);
                },
              ),
              const Divider(height: 1),
              _VolumeSlider(
                label: context.tr('Volumen de toques'),
                value: s.touchVolume,
                enabled: s.soundEnabled,
                onChanged: (v) => setTouchVolume(v, persist: false),
                onChangeEnd: (v) {
                  setTouchVolume(v);
                  AppSounds.play(AppSound.button);
                },
              ),
              const Divider(height: 1),
              _VolumeSlider(
                label: context.tr('Volumen de compra exitosa'),
                value: s.paidVolume,
                enabled: s.soundEnabled,
                onChanged: (v) => setPaidVolume(v, persist: false),
                onChangeEnd: (v) {
                  setPaidVolume(v);
                  AppSounds.play(AppSound.paid);
                },
              ),
            ],
          )),
          const SizedBox(height: 16),
          _card(Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
                child: Row(
                  children: [
                    const Icon(Icons.music_note_outlined,
                        size: 20, color: AppColors.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(context.tr('Pago exitoso'),
                              style: const TextStyle(fontSize: 15)),
                          Text(context.tr('Se reproduce al confirmar el pago'),
                              style: const TextStyle(
                                  color: AppColors.muted, fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              for (final option in paidSoundOptions) ...[
                const Divider(height: 1),
                InkWell(
                  onTap: () {
                    setPaidSound(option.id);
                    if (s.soundEnabled) AppSounds.play(AppSound.paid);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      children: [
                        Icon(
                          s.paidSoundId == option.id
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off,
                          size: 20,
                          color: s.paidSoundId == option.id
                              ? AppColors.primary
                              : AppColors.muted,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(context.tr(option.label),
                              style: const TextStyle(fontSize: 15)),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          )),
        ];
      case SettingsSection.relays:
        return [
          _countLine(context, s.relays.length,
              s.relays.length == 1 ? 'relay' : 'relays'),
          _RelaysCard(relays: s.relays),
        ];
      case SettingsSection.printer:
        return [
          _card(Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.print_outlined,
                        size: 20, color: AppColors.primary),
                    const SizedBox(width: 8),
                    Text(context.tr('Impresora ZCS SmartPos'),
                        style: const TextStyle(fontSize: 15)),
                  ],
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => _testPrint(context),
                  icon: const Icon(Icons.receipt_long, size: 20),
                  label: Text(context.tr('Probar impresora')),
                ),
              ],
            ),
          )),
        ];
      case SettingsSection.coupons:
        return [
          _countLine(context, s.prizeCoupons.length,
              s.prizeCoupons.length == 1 ? 'premio' : 'premios'),
          _PrizeCouponsCard(
            enabled: s.prizePrintEnabled,
            coupons: s.prizeCoupons,
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => context.push('/settings/cupones/ruleta'),
              icon: const Icon(Icons.casino_outlined),
              label: Text(context.tr('Configurar Ruleta')),
            ),
          ),
        ];
    }
  }
}

/// Wheel timing, when it appears, and the try button. Opened from Cupones.
class WheelSettingsScreen extends StatelessWidget {
  const WheelSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PosAppBar(
        title: context.tr('Configurar Ruleta'),
        showSettings: false,
      ),
      body: ValueListenableBuilder<SettingsState>(
        valueListenable: appSettings,
        builder: (context, s, _) {
          final canSpin = wheelHasPrizes(s.prizeCoupons);
          return PosBody(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                _WheelOfferCard(offer: s.wheelOffer),
                _WheelDurationSlider(milliseconds: s.wheelDurationMs),
                _WheelPaceSlider(
                  label: context.tr('Aceleración'),
                  value: s.wheelAcceleration,
                  onChanged: (value) =>
                      setWheelAcceleration(value, persist: false),
                  onChangeEnd: setWheelAcceleration,
                ),
                _WheelPaceSlider(
                  label: context.tr('Velocidad'),
                  value: s.wheelSpeed,
                  onChanged: (value) => setWheelSpeed(value, persist: false),
                  onChangeEnd: setWheelSpeed,
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _card(
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      activeTrackColor: AppColors.primary,
                      title: Text(context.tr('Imprimir ticket en modo prueba')),
                      value: s.wheelPracticePrint,
                      onChanged: setWheelPracticePrint,
                    ),
                  ),
                ),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: canSpin
                        ? () => context.push('/settings/cupones/ruleta/probar')
                        : null,
                    icon: const Icon(Icons.casino_outlined),
                    label: Text(context.tr('Probar')),
                  ),
                ),
                if (!canSpin)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      context.tr('No hay premios'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 15),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _WheelOfferCard extends StatelessWidget {
  const _WheelOfferCard({required this.offer});

  final WheelOffer offer;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: _card(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(context.tr('Mostrar la ruleta'),
                  style: const TextStyle(fontSize: 15)),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: _chip(context, 'Siempre', WheelOffer.always)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _chip(context, 'Solo con propina', WheelOffer.tipOnly),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, String label, WheelOffer value) {
    final selected = offer == value;
    return Material(
      color: selected ? AppColors.primary : AppColors.background,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _selectWheelOffer(context, value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Text(context.tr(label),
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: selected ? AppColors.background : AppColors.onDark)),
        ),
      ),
    );
  }
}

Future<void> _selectWheelOffer(BuildContext context, WheelOffer value) async {
  if (value == WheelOffer.always || appSettings.value.tipEnabled) {
    setWheelOffer(value);
    return;
  }
  final enable = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(context.tr('Activar propina')),
      content: Text(context.tr(
          'Para mostrar la ruleta solo con propina, hay que activar la pantalla de propina.')),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(context.tr('Cancelar'),
              style: const TextStyle(color: AppColors.muted)),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(context.tr('Activar')),
        ),
      ],
    ),
  );
  if (enable != true || !context.mounted) return;
  setTipEnabled(true);
  setWheelOffer(WheelOffer.tipOnly);
}

Future<void> _onTipChanged(
  BuildContext context,
  bool enabled,
  WheelOffer offer,
) async {
  if (enabled || offer != WheelOffer.tipOnly) {
    setTipEnabled(enabled);
    return;
  }
  final showAlways = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      content: Text(context.tr(
          'Si desactivás la propina, la ruleta deja de mostrarse. ¿Querés mostrarla siempre?')),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(context.tr('Cancelar'),
              style: const TextStyle(color: AppColors.muted)),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(context.tr('No'),
              style: const TextStyle(color: AppColors.muted)),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(context.tr('Siempre')),
        ),
      ],
    ),
  );
  if (showAlways == null || !context.mounted) return;
  setTipEnabled(false);
  if (showAlways) setWheelOffer(WheelOffer.always);
}

class _WheelPaceSlider extends StatelessWidget {
  const _WheelPaceSlider({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final shown = clampWheelPace(value);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: _card(
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(label, style: const TextStyle(fontSize: 15)),
                  ),
                  Text('${shown.toStringAsFixed(1)}×',
                      style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 14,
                          fontWeight: FontWeight.w700)),
                ],
              ),
              _PosSlider(
                min: kWheelPaceMin,
                max: kWheelPaceMax,
                divisions: 15,
                value: shown,
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WheelDurationSlider extends StatelessWidget {
  const _WheelDurationSlider({required this.milliseconds});

  final int milliseconds;

  @override
  Widget build(BuildContext context) {
    final seconds = (milliseconds / 1000)
        .round()
        .clamp(kWheelDurationMinMs ~/ 1000, kWheelDurationMaxMs ~/ 1000);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: _card(
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(context.tr('Duración de la ruleta'),
                        style: const TextStyle(fontSize: 15)),
                  ),
                  Text('$seconds s',
                      style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 14,
                          fontWeight: FontWeight.w700)),
                ],
              ),
              _PosSlider(
                min: kWheelDurationMinMs / 1000,
                max: kWheelDurationMaxMs / 1000,
                divisions: (kWheelDurationMaxMs - kWheelDurationMinMs) ~/ 1000,
                value: seconds.toDouble(),
                onChanged: (value) =>
                    setWheelDuration(value.round() * 1000, persist: false),
                onChangeEnd: (value) => setWheelDuration(value.round() * 1000),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Track control without [Slider]. The material slider keeps a value
/// indicator in the route overlay, and leaving the page asserts
/// `_dependents.isEmpty` while that indicator is still registered.
class _PosSlider extends StatefulWidget {
  const _PosSlider({
    required this.value,
    required this.onChanged,
    this.onChangeEnd,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.enabled = true,
  });

  final double value;
  final double min;
  final double max;
  final int? divisions;
  final bool enabled;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  State<_PosSlider> createState() => _PosSliderState();
}

class _PosSliderState extends State<_PosSlider> {
  double? _drag;

  double _at(double dx, double width) {
    final span = widget.max - widget.min;
    final t = width <= 0 ? 0.0 : (dx / width).clamp(0.0, 1.0);
    var next = widget.min + t * span;
    final divisions = widget.divisions;
    if (divisions != null && divisions > 0) {
      final step = span / divisions;
      next = widget.min + ((next - widget.min) / step).round() * step;
    }
    return next.clamp(widget.min, widget.max);
  }

  void _emit(double dx, double width, {required bool end}) {
    if (!widget.enabled) return;
    final next = _at(dx, width);
    setState(() => _drag = next);
    widget.onChanged(next);
    if (!end) return;
    widget.onChangeEnd?.call(next);
    setState(() => _drag = null);
  }

  @override
  Widget build(BuildContext context) {
    final span = widget.max - widget.min;
    final shown = _drag ?? widget.value;
    final t = span == 0 ? 0.0 : ((shown - widget.min) / span).clamp(0.0, 1.0);
    final color = widget.enabled ? AppColors.primary : AppColors.muted;
    return SizedBox(
      height: 40,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: widget.enabled
                  ? (details) => _emit(details.localPosition.dx, width, end: false)
                  : null,
              onHorizontalDragEnd: widget.enabled
                  ? (_) {
                      final next = _drag ?? widget.value;
                      widget.onChangeEnd?.call(next);
                      setState(() => _drag = null);
                    }
                  : null,
              onTapUp: widget.enabled
                  ? (details) => _emit(details.localPosition.dx, width, end: true)
                  : null,
              child: Center(
                child: SizedBox(
                  height: 24,
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        height: 6,
                        decoration: BoxDecoration(
                          color: AppColors.background,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      FractionallySizedBox(
                        widthFactor: t,
                        child: Container(
                          height: 6,
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment(t * 2 - 1, 0),
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _VolumeSlider extends StatelessWidget {
  const _VolumeSlider({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String label;
  final double value;
  final bool enabled;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final shown = (value * 100).round();
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label,
                    style: TextStyle(
                        fontSize: 15,
                        color: enabled ? AppColors.onDark : AppColors.muted)),
              ),
              Text('$shown%',
                  style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
            ],
          ),
          _PosSlider(
            value: value.clamp(0.0, 1.0),
            enabled: enabled,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ],
      ),
    );
  }
}

Widget _countLine(BuildContext context, int count, String unitKey) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        '$count ${context.tr(unitKey)}',
        style: const TextStyle(color: AppColors.muted, fontSize: 13),
      ),
    );

class _VersionFooter extends StatelessWidget {
  const _VersionFooter();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: FutureBuilder<PackageInfo>(
          future: _packageInfo,
          builder: (context, snap) {
            final info = snap.data;
            final label = info != null
                ? 'v${info.version} (${info.buildNumber})'
                : 'v$kFallbackVersion';
            return Text(label,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.muted, fontSize: 12));
          },
        ),
      ),
    );
  }
}

Future<void> _testPrint(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
        content: Text(context.tr('Imprimiendo prueba…')),
        duration: const Duration(seconds: 1)));
    final res = await PrinterChannel.testPrint();
    if (!context.mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text(res.message),
      backgroundColor: res.ok ? AppColors.primary : AppColors.error,
    ));
  }

Widget _card(Widget child) => Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: child,
      ),
    );

/// Segmented language selector (Español / English).
class _LanguageSelector extends StatelessWidget {
  final String current;
  const _LanguageSelector({required this.current});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.language, size: 20, color: AppColors.primary),
        const SizedBox(width: 8),
        Expanded(
            child: Text(context.tr('Idioma'),
                style: const TextStyle(fontSize: 15))),
        for (final l in AppLanguage.values)
          Padding(
            padding: EdgeInsets.only(left: l == AppLanguage.values.first ? 0 : 8),
            child: _chip(
              label: l.label,
              selected: current == l.code,
              onTap: () => setLanguage(l.code),
            ),
          ),
      ],
    );
  }

  Widget _chip(
      {required String label,
      required bool selected,
      required VoidCallback onTap}) {
    return Material(
      color: selected ? AppColors.primary : AppColors.background,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Text(label,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: selected ? AppColors.background : AppColors.onDark)),
        ),
      ),
    );
  }
}

/// The relays card: editable/removable active relays, an add field, quick-add
/// suggestions, and a reset.
class _RelaysCard extends StatefulWidget {
  final List<String> relays;
  const _RelaysCard({required this.relays});
  @override
  State<_RelaysCard> createState() => _RelaysCardState();
}

class _RelaysCardState extends State<_RelaysCard> {
  final _addCtrl = TextEditingController();

  @override
  void dispose() {
    _addCtrl.dispose();
    super.dispose();
  }

  void _snack(String msgKey) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.tr(msgKey)), backgroundColor: AppColors.error));

  void _submitAdd() {
    final text = _addCtrl.text;
    if (text.trim().isEmpty) return;
    if (addRelay(text)) {
      _addCtrl.clear();
      FocusScope.of(context).unfocus();
    } else {
      _snack('URL inválida o repetida');
    }
  }

  Future<void> _editRelay(int index, String current) async {
    final ctrl = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(context.tr('Editar relay')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            filled: true,
            fillColor: AppColors.background,
            hintText: 'wss://relay.example.com',
            border: OutlineInputBorder(
                borderSide: BorderSide.none,
                borderRadius: BorderRadius.all(Radius.circular(12))),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(context.tr('Cancelar'),
                style: const TextStyle(color: AppColors.muted)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: Text(context.tr('Guardar')),
          ),
        ],
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      if (!updateRelay(index, result)) _snack('URL inválida o repetida');
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.relays;
    final suggestions =
        kSuggestedRelays.where((r) => !active.contains(r)).toList();
    return _card(Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 4),
        for (var i = 0; i < active.length; i++) ...[
          if (i > 0) const Divider(height: 1),
          _relayRow(i, active[i], canDelete: active.length > 1),
        ],
        const SizedBox(height: 8),
        // Add a new relay.
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _addCtrl,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: AppColors.background,
                  hintText: 'wss://relay.example.com',
                  hintStyle:
                      const TextStyle(color: AppColors.muted, fontSize: 13),
                  border: const OutlineInputBorder(
                      borderSide: BorderSide.none,
                      borderRadius: BorderRadius.all(Radius.circular(12))),
                ),
                onSubmitted: (_) => _submitAdd(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 48),
                padding: const EdgeInsets.symmetric(horizontal: 18),
              ),
              onPressed: _submitAdd,
              child: Text(context.tr('Agregar')),
            ),
          ],
        ),
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(context.tr('Sugeridos'),
                style: const TextStyle(color: AppColors.muted, fontSize: 12)),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final r in suggestions)
                ActionChip(
                  backgroundColor: AppColors.background,
                  side: BorderSide.none,
                  avatar: const Icon(Icons.add,
                      size: 16, color: AppColors.primary),
                  label: Text(r.replaceFirst('wss://', ''),
                      style: const TextStyle(fontSize: 12)),
                  onPressed: () => toggleRelay(r),
                ),
            ],
          ),
        ],
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: resetRelays,
            icon: const Icon(Icons.restart_alt, size: 18),
            label: Text(context.tr('Restablecer')),
          ),
        ),
      ],
    ));
  }

  Widget _relayRow(int index, String url, {required bool canDelete}) {
    return InkWell(
      onTap: () => _editRelay(index, url),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.podcasts_rounded,
                size: 18, color: AppColors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(url.replaceFirst('wss://', ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14)),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.edit_outlined,
                  size: 18, color: AppColors.muted),
              onPressed: () => _editRelay(index, url),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close_rounded,
                  size: 18,
                  color: canDelete
                      ? AppColors.error
                      : AppColors.muted.withValues(alpha: 0.4)),
              onPressed: canDelete ? () => removeRelay(url) : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _EditedPrize {
  const _EditedPrize({required this.text, required this.chance});

  final String text;
  final int chance;
}

/// Owns the fields so they unfocus before the route goes away. Closing a
/// focused text field with the route still tears down an overlay that is
/// registered on the route's inherited widgets.
class _EditPrizeDialog extends StatefulWidget {
  const _EditPrizeDialog({required this.coupon});

  final PrizeCoupon coupon;

  @override
  State<_EditPrizeDialog> createState() => _EditPrizeDialogState();
}

class _EditPrizeDialogState extends State<_EditPrizeDialog> {
  late final TextEditingController _text;
  late final TextEditingController _chance;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.coupon.text);
    _chance =
        TextEditingController(text: widget.coupon.chancePercent.toString());
  }

  @override
  void dispose() {
    _text.dispose();
    _chance.dispose();
    super.dispose();
  }

  int _chanceValue() {
    final v = int.tryParse(_chance.text.trim());
    if (v == null) return 0;
    return v.clamp(0, 100);
  }

  Future<void> _close({required bool save}) async {
    if (_closing) return;
    setState(() => _closing = true);
    FocusManager.instance.primaryFocus?.unfocus();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    Navigator.of(context).pop(
      save ? _EditedPrize(text: _text.text, chance: _chanceValue()) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _closing,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _close(save: false);
      },
      child: AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(context.tr('Editar premio')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _text,
              autofocus: true,
              decoration: InputDecoration(
                filled: true,
                fillColor: AppColors.background,
                labelText: context.tr('Premio'),
                border: const OutlineInputBorder(
                    borderSide: BorderSide.none,
                    borderRadius: BorderRadius.all(Radius.circular(12))),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _chance,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                filled: true,
                fillColor: AppColors.background,
                labelText: context.tr('Probabilidad %'),
                border: const OutlineInputBorder(
                    borderSide: BorderSide.none,
                    borderRadius: BorderRadius.all(Radius.circular(12))),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => _close(save: false),
            child: Text(context.tr('Cancelar'),
                style: const TextStyle(color: AppColors.muted)),
          ),
          FilledButton(
            onPressed: () => _close(save: true),
            child: Text(context.tr('Guardar')),
          ),
        ],
      ),
    );
  }
}

/// Prize coupons: enable toggle and the editable text + chance list.
class _PrizeCouponsCard extends StatefulWidget {
  final bool enabled;
  final List<PrizeCoupon> coupons;
  const _PrizeCouponsCard({
    required this.enabled,
    required this.coupons,
  });
  @override
  State<_PrizeCouponsCard> createState() => _PrizeCouponsCardState();
}

class _PrizeCouponsCardState extends State<_PrizeCouponsCard> {
  final _textCtrl = TextEditingController();
  final _chanceCtrl = TextEditingController(text: '10');

  @override
  void dispose() {
    _textCtrl.dispose();
    _chanceCtrl.dispose();
    super.dispose();
  }

  void _snack(String msgKey) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.tr(msgKey)), backgroundColor: AppColors.error));

  int _parseChance(String raw) {
    final v = int.tryParse(raw.trim());
    if (v == null) return 0;
    return v.clamp(0, 100);
  }

  void _submitAdd() {
    final text = _textCtrl.text;
    if (text.trim().isEmpty) {
      _snack('Texto inválido');
      return;
    }
    if (addPrizeCoupon(text, _parseChance(_chanceCtrl.text))) {
      _textCtrl.clear();
      _chanceCtrl.text = '10';
      FocusScope.of(context).unfocus();
    } else {
      _snack('Texto inválido');
    }
  }

  Future<void> _editCoupon(PrizeCoupon coupon) async {
    final result = await showDialog<_EditedPrize>(
      context: context,
      builder: (ctx) => _EditPrizeDialog(coupon: coupon),
    );
    if (result == null) return;
    if (!updatePrizeCoupon(coupon.id, result.text, result.chance)) {
      _snack('Texto inválido');
    }
  }

  @override
  Widget build(BuildContext context) {
    final coupons = widget.coupons;
    return _card(Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          activeTrackColor: AppColors.primary,
          title: Text(context.tr('Cupones de premio')),
          subtitle: Text(
              context.tr('Imprimir cupones de premio después del cobro'),
              style: const TextStyle(color: AppColors.muted, fontSize: 12)),
          value: widget.enabled,
          onChanged: setPrizePrintEnabled,
        ),
        if (widget.enabled) ...[
          const Divider(height: 1),
          for (var i = 0; i < coupons.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            InkWell(
              onTap: () => _editCoupon(coupons[i]),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    const Icon(Icons.emoji_events_outlined,
                        size: 18, color: AppColors.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(coupons[i].text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14)),
                    ),
                    Text('${coupons[i].chancePercent}%',
                        style: const TextStyle(
                            color: AppColors.muted,
                            fontWeight: FontWeight.w600,
                            fontSize: 13)),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.edit_outlined,
                          size: 18, color: AppColors.muted),
                      onPressed: () => _editCoupon(coupons[i]),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close_rounded,
                          size: 18, color: AppColors.error),
                      onPressed: () => removePrizeCoupon(coupons[i].id),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _textCtrl,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: AppColors.background,
                    hintText: context.tr('Premio'),
                    hintStyle:
                        const TextStyle(color: AppColors.muted, fontSize: 13),
                    border: const OutlineInputBorder(
                        borderSide: BorderSide.none,
                        borderRadius: BorderRadius.all(Radius.circular(12))),
                  ),
                  onSubmitted: (_) => _submitAdd(),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 72,
                child: TextField(
                  controller: _chanceCtrl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: AppColors.background,
                    hintText: '%',
                    hintStyle:
                        const TextStyle(color: AppColors.muted, fontSize: 13),
                    border: const OutlineInputBorder(
                        borderSide: BorderSide.none,
                        borderRadius: BorderRadius.all(Radius.circular(12))),
                  ),
                  onSubmitted: (_) => _submitAdd(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                ),
                onPressed: _submitAdd,
                child: Text(context.tr('Agregar')),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ],
    ));
  }
}
