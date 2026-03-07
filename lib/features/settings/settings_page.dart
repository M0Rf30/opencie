// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_constants.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/color_schemes.dart';
import '../../models/proxy_config.dart';
import '../../models/signature_options.dart';
import '../../providers/settings_provider.dart';
import '../../services/storage_service.dart';
import '../../widgets/oc_action_row.dart';
import '../../widgets/oc_help_sheet.dart';
import '../../widgets/oc_mark.dart'; // used in About section
import '../../widgets/oc_section_label.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  // Proxy text controllers
  final _proxyHost = TextEditingController();
  final _proxyPort = TextEditingController();
  final _proxyUser = TextEditingController();
  final _proxyPass = TextEditingController();

  // OIDC text controllers
  final _oidcIssuer = TextEditingController();
  final _oidcClientId = TextEditingController();

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _proxyHost.text = settings.proxyConfig.host;
    _proxyPort.text =
        settings.proxyConfig.port == 0 ? '' : settings.proxyConfig.port.toString();
    _proxyUser.text = settings.proxyConfig.username;
    _proxyPass.text = settings.proxyConfig.password;
    _oidcIssuer.text = settings.oidcIssuer;
    _oidcClientId.text = settings.oidcClientId;
  }

  @override
  void dispose() {
    _proxyHost.dispose();
    _proxyPort.dispose();
    _proxyUser.dispose();
    _proxyPass.dispose();
    _oidcIssuer.dispose();
    _oidcClientId.dispose();
    super.dispose();
  }

  void _showProxyDialog() {
    final settings = ref.read(settingsProvider);
    // Sync controllers with current state
    _proxyHost.text = settings.proxyConfig.host;
    _proxyPort.text =
        settings.proxyConfig.port == 0 ? '' : settings.proxyConfig.port.toString();
    _proxyUser.text = settings.proxyConfig.username;
    _proxyPass.text = settings.proxyConfig.password;

    showDialog<void>(
      context: context,
      builder: (ctx) => _ProxyDialog(
        proxyHost: _proxyHost,
        proxyPort: _proxyPort,
        proxyUser: _proxyUser,
        proxyPass: _proxyPass,
      ),
    );
  }

  void _showOidcDialog() {
    final settings = ref.read(settingsProvider);
    _oidcIssuer.text = settings.oidcIssuer;
    _oidcClientId.text = settings.oidcClientId;

    showDialog<void>(
      context: context,
      builder: (ctx) => _OidcDialog(
        oidcIssuer: _oidcIssuer,
        oidcClientId: _oidcClientId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final settings = ref.watch(settingsProvider);
    final l10n = AppLocalizations.of(context);

    // TSA providers: FreeTSA + qualified Italian TSPs
    final tsaEntries = <MapEntry<String, String>>[
      const MapEntry('FreeTSA', AppConstants.defaultTsaUrl),
      ...AppConstants.qualifiedTsaProviders.entries,
    ];

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // ── Page heading ─────────────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 8, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.settingsTitle, style: AppTheme.displayBold(cs)),
                        const SizedBox(height: 6),
                        Text(
                          l10n.settingsSubtitle,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 13,
                            fontWeight: FontWeight.w400,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.info_outline_rounded),
                    tooltip: l10n.helpButtonTooltip,
                    onPressed: () => OcHelpSheet.show(
                      context,
                      OcHelpSheet(
                        title: l10n.helpSettingsTitle,
                        icon: Icons.settings_rounded,
                        iconColor: cs.primary,
                        steps: [
                          OcHelpStep(title: l10n.helpSettingsStep1Title, body: l10n.helpSettingsStep1Body, icon: Icons.draw_rounded),
                          OcHelpStep(title: l10n.helpSettingsStep2Title, body: l10n.helpSettingsStep2Body, icon: Icons.schedule_rounded),
                          OcHelpStep(title: l10n.helpSettingsStep3Title, body: l10n.helpSettingsStep3Body, icon: Icons.security_rounded),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 28)),

          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverList(
              delegate: SliverChildListDelegate([

                // ── 0. INTERFACCIA ────────────────────────────────────────
                OcSectionLabel(l10n.settingsInterfaceTitle),
                const SizedBox(height: 8),
                OcGroupCard(
                  children: [
                    // Theme row
                    OcActionRow(
                      leadingIcon: Icons.brightness_6_outlined,
                      title: l10n.settingsThemeTitle,
                      subtitle: _getThemeModeLabel(settings.themeMode, l10n),
                      onTap: () => _showThemeDialog(context, ref, l10n),
                    ),
                    // UI Scale row
                    OcActionRow(
                      leadingIcon: Icons.format_size_outlined,
                      title: l10n.settingsScaleTitle,
                      subtitle: '${(settings.uiScale * 100).round()}%',
                      onTap: () => _showScaleDialog(context, ref, l10n),
                    ),
                  ],
                ),

                const SizedBox(height: 20),

                // ── 1. AUTORITÀ DI MARCATURA (TSA) ────────────────────────
                OcSectionLabel(l10n.settingsTsa),
                const SizedBox(height: 8),
                OcGroupCard(
                  children: tsaEntries.map((entry) {
                    final isSelected =
                        settings.tsaConfig.serverUrl == entry.value;
                    return OcActionRow(
                      leading: _RadioDot(selected: isSelected, cs: cs),
                      title: entry.key,
                      subtitle: entry.value,
                      subtitleMono: true,
                      onTap: () => ref
                          .read(settingsProvider.notifier)
                          .update((s) => s.copyWith(
                              tsaConfig:
                                  s.tsaConfig.copyWith(serverUrl: entry.value))),
                    );
                  }).toList(),
                ),

                const SizedBox(height: 20),

                // ── 2. SALVATAGGIO ────────────────────────────────────────
                OcSectionLabel(l10n.settingsGeneral),
                const SizedBox(height: 8),
                OcGroupCard(
                  children: [
                    OcActionRow(
                      leadingIcon: Icons.folder_outlined,
                      title: l10n.settingsDestinationFolder,
                      subtitle: settings.destinationFolder ?? l10n.settingsSameAsDocument,
                      subtitleMono: settings.destinationFolder != null,
                      trailing: settings.destinationFolder != null
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: Icon(Icons.close_rounded,
                                      size: 18,
                                      color: cs.onSurfaceVariant),
                                  tooltip: l10n.commonClear,
                                  onPressed: () => ref
                                      .read(settingsProvider.notifier)
                                      .clearDestinationFolder(),
                                ),
                                Icon(Icons.chevron_right_rounded,
                                    color: cs.onSurfaceVariant, size: 22),
                              ],
                            )
                          : null,
                      onTap: () async {
                        String? picked;
                        if (Platform.isAndroid) {
                          picked = await StorageService.pickOutputFolder();
                        } else {
                          picked = await FilePicker.getDirectoryPath();
                        }
                        if (picked != null) {
                          ref.read(settingsProvider.notifier).update(
                              (s) => s.copyWith(destinationFolder: picked));
                        }
                      },
                    ),
                    OcActionRow(
                      title: l10n.settingsOpenAfterSign,
                      trailing: Switch.adaptive(
                        value: settings.openFolderAfterSign,
                        activeTrackColor: ColorSchemes.primary,
                        onChanged: (v) => ref
                            .read(settingsProvider.notifier)
                            .update((s) => s.copyWith(openFolderAfterSign: v)),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 20),

                // ── 3. FIRMA ──────────────────────────────────────────────
                OcSectionLabel(l10n.settingsSignature),
                const SizedBox(height: 8),
                OcGroupCard(
                  children: [
                    // PDF format radios
                    ...SignatureFormat.values
                        .where((f) =>
                            f == SignatureFormat.pades ||
                            f == SignatureFormat.cades)
                        .map((f) {
                      final isSelected = settings.defaultPdfFormat == f;
                      return OcActionRow(
                        leading: _RadioDot(selected: isSelected, cs: cs),
                        title: f.displayName,
                        subtitle: l10n.settingsDefaultPdfFormat,
                        onTap: () => ref
                            .read(settingsProvider.notifier)
                            .update((s) =>
                                s.copyWith(defaultPdfFormat: f)),
                      );
                    }),
                    OcActionRow(
                      title: l10n.settingsGraphicPades,
                      trailing: Switch.adaptive(
                        value: settings.graphicPades,
                        activeTrackColor: ColorSchemes.primary,
                        onChanged: (v) => ref
                            .read(settingsProvider.notifier)
                            .update((s) => s.copyWith(graphicPades: v)),
                      ),
                    ),
                    if (settings.graphicPades) ...[
                      OcActionRow(
                        title: l10n.settingsEnableDate,
                        trailing: Switch.adaptive(
                          value: settings.includeDate,
                          activeTrackColor: ColorSchemes.primary,
                          onChanged: (v) => ref
                              .read(settingsProvider.notifier)
                              .update((s) => s.copyWith(includeDate: v)),
                        ),
                      ),
                      OcActionRow(
                        title: l10n.settingsEnableLocation,
                        trailing: Switch.adaptive(
                          value: settings.includeLocation,
                          activeTrackColor: ColorSchemes.primary,
                          onChanged: (v) => ref
                              .read(settingsProvider.notifier)
                              .update((s) => s.copyWith(includeLocation: v)),
                        ),
                      ),
                      OcActionRow(
                        title: l10n.settingsEnableReason,
                        trailing: Switch.adaptive(
                          value: settings.includeReason,
                          activeTrackColor: ColorSchemes.primary,
                          onChanged: (v) => ref
                              .read(settingsProvider.notifier)
                              .update((s) => s.copyWith(includeReason: v)),
                        ),
                      ),
                    ],
                    OcActionRow(
                      title: l10n.settingsPreservePdfA,
                      trailing: Switch.adaptive(
                        value: settings.preservePdfA,
                        activeTrackColor: ColorSchemes.primary,
                        onChanged: (v) => ref
                            .read(settingsProvider.notifier)
                            .update((s) => s.copyWith(preservePdfA: v)),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 20),

                // ── 4. VALIDAZIONE ────────────────────────────────────────
                OcSectionLabel(l10n.settingsValidation),
                const SizedBox(height: 8),
                OcGroupCard(
                  children: [
                    OcActionRow(
                      leading: _RadioDot(
                          selected:
                              settings.validationType == ValidationType.ocspOnly,
                          cs: cs),
                      title: l10n.settingsOcspOnly,
                      onTap: () => ref
                          .read(settingsProvider.notifier)
                          .update((s) => s.copyWith(
                              validationType: ValidationType.ocspOnly)),
                    ),
                    OcActionRow(
                      leading: _RadioDot(
                          selected:
                              settings.validationType == ValidationType.ocspFirst,
                          cs: cs),
                      title: l10n.settingsOcspFirst,
                      onTap: () => ref
                          .read(settingsProvider.notifier)
                          .update((s) => s.copyWith(
                              validationType: ValidationType.ocspFirst)),
                    ),
                    OcActionRow(
                      leading: _RadioDot(
                          selected:
                              settings.validationType == ValidationType.crlOnly,
                          cs: cs),
                      title: l10n.settingsCrlOnly,
                      onTap: () => ref
                          .read(settingsProvider.notifier)
                          .update((s) => s.copyWith(
                              validationType: ValidationType.crlOnly)),
                    ),
                    OcActionRow(
                      leading: _RadioDot(
                          selected:
                              settings.validationType == ValidationType.crlFirst,
                          cs: cs),
                      title: l10n.settingsCrlFirst,
                      onTap: () => ref
                          .read(settingsProvider.notifier)
                          .update((s) => s.copyWith(
                              validationType: ValidationType.crlFirst)),
                    ),
                  ],
                ),

                const SizedBox(height: 20),

                // ── 5. RETE (Proxy) ───────────────────────────────────────
                OcSectionLabel(l10n.settingsProxy),
                const SizedBox(height: 8),
                OcGroupCard(
                  children: [
                    OcActionRow(
                      leading: _ProxyStatusDot(
                          mode: settings.proxyConfig.mode),
                      title: l10n.settingsProxy,
                      subtitle: _proxySubtitle(settings.proxyConfig, l10n),
                      subtitleMono: settings.proxyConfig.mode == ProxyMode.manual,
                      onTap: _showProxyDialog,
                    ),
                  ],
                ),

                const SizedBox(height: 20),

                // ── 6. OIDC / AUTENTICAZIONE ──────────────────────────────
                OcSectionLabel(l10n.settingsOidc),
                const SizedBox(height: 8),
                OcGroupCard(
                  children: [
                    OcActionRow(
                      leadingIcon: Icons.security_outlined,
                      title: l10n.settingsOidcIssuer,
                      subtitle: settings.oidcIssuer,
                      subtitleMono: true,
                      onTap: _showOidcDialog,
                    ),
                    OcActionRow(
                      leadingIcon: Icons.vpn_key_outlined,
                      title: l10n.settingsOidcClientId,
                      subtitle: settings.oidcClientId,
                      subtitleMono: true,
                      onTap: _showOidcDialog,
                    ),
                  ],
                ),

                const SizedBox(height: 20),

                // ── 7. APP (log level + about) ────────────────────────────
                OcSectionLabel(l10n.settingsAbout),
                const SizedBox(height: 8),
                OcGroupCard(
                  children: [
                    ...LogLevel.values.map((level) {
                      final isSelected = settings.logLevel == level;
                      return OcActionRow(
                        leading: _RadioDot(selected: isSelected, cs: cs),
                        title: _logLevelLabel(level, l10n),
                        onTap: () => ref
                            .read(settingsProvider.notifier)
                            .update((s) => s.copyWith(logLevel: level)),
                      );
                    }),
                  ],
                ),

                const SizedBox(height: 12),

                // About card
                OcGroupCard(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
                      child: Column(
                        children: [
                          const OcMark(size: 56),
                          const SizedBox(height: 12),
                          Text(
                            l10n.appTitle,
                            style: TextStyle(fontFamily: 'Inter', 
                              color: cs.primary,
                              fontWeight: FontWeight.w800,
                              fontSize: 17,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            l10n.settingsAboutDescription,
                            style: TextStyle(fontFamily: 'Inter', 
                              color: cs.onSurfaceVariant,
                              fontSize: 12,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _LinkTile(
                                icon: Icons.code,
                                label: 'opencie',
                                url: 'https://github.com/M0Rf30/opencie',
                                cs: cs,
                              ),
                              const SizedBox(width: 16),
                              _LinkTile(
                                icon: Icons.bug_report_outlined,
                                label: l10n.settingsAboutReportIssue,
                                url:
                                    'https://github.com/M0Rf30/opencie/issues',
                                cs: cs,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 20),

                // ── Footer ────────────────────────────────────────────────
                Center(
                  child: Text(
                    'OpenCIE 0.1.0+1 · GPL-2.0',
                    style: AppTheme.monoCaption(cs,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
                  ),
                ),

                const SizedBox(height: 40),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  String _proxySubtitle(ProxyConfig proxy, AppLocalizations l10n) {
    switch (proxy.mode) {
      case ProxyMode.none:
        return l10n.settingsNoProxy;
      case ProxyMode.system:
        return l10n.settingsSystemProxy;
      case ProxyMode.manual:
        return proxy.host.isNotEmpty
            ? '${proxy.host}:${proxy.port}'
            : l10n.settingsManualProxy;
    }
  }

  String _logLevelLabel(LogLevel level, AppLocalizations l10n) {
    switch (level) {
      case LogLevel.off:
        return 'Off';
      case LogLevel.standard:
        return 'Standard';
      case LogLevel.debug:
        return 'Debug';
    }
  }

  String _getThemeModeLabel(ThemeMode mode, AppLocalizations l10n) {
    switch (mode) {
      case ThemeMode.system:
        return l10n.settingsThemeAuto;
      case ThemeMode.light:
        return l10n.settingsThemeLight;
      case ThemeMode.dark:
        return l10n.settingsThemeDark;
    }
  }

  void _showThemeDialog(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) {
    final settings = ref.read(settingsProvider);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.settingsThemeTitle),
        content: RadioGroup<ThemeMode>(
          groupValue: settings.themeMode,
          onChanged: (mode) {
            if (mode != null) {
              ref.read(settingsProvider.notifier).setThemeMode(mode);
              Navigator.pop(ctx);
            }
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<ThemeMode>(
                title: Text(l10n.settingsThemeAuto),
                value: ThemeMode.system,
              ),
              RadioListTile<ThemeMode>(
                title: Text(l10n.settingsThemeLight),
                value: ThemeMode.light,
              ),
              RadioListTile<ThemeMode>(
                title: Text(l10n.settingsThemeDark),
                value: ThemeMode.dark,
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.commonClose),
          ),
        ],
      ),
    );
  }

  void _showScaleDialog(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) {
    final settings = ref.read(settingsProvider);
    const scales = [0.85, 1.0, 1.15, 1.30, 1.45];
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.settingsScaleTitle),
        content: RadioGroup<double>(
          groupValue: settings.uiScale,
          onChanged: (value) {
            if (value != null) {
              ref.read(settingsProvider.notifier).setUiScale(value);
              Navigator.pop(ctx);
            }
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: scales
                .map((scale) => RadioListTile<double>(
                      title: Text('${(scale * 100).round()}%'),
                      value: scale,
                    ))
                .toList(),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.commonClose),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// OIDC dialog
// ---------------------------------------------------------------------------

class _OidcDialog extends ConsumerWidget {
  const _OidcDialog({
    required this.oidcIssuer,
    required this.oidcClientId,
  });

  final TextEditingController oidcIssuer;
  final TextEditingController oidcClientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);

    return AlertDialog(
      icon: const Icon(Icons.security_outlined),
      title: Text(l10n.settingsOidc),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: oidcIssuer,
              decoration: InputDecoration(labelText: l10n.settingsOidcIssuer),
              onChanged: (v) => ref
                  .read(settingsProvider.notifier)
                  .update((s) => s.copyWith(oidcIssuer: v)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: oidcClientId,
              decoration: InputDecoration(labelText: l10n.settingsOidcClientId),
              onChanged: (v) => ref
                  .read(settingsProvider.notifier)
                  .update((s) => s.copyWith(oidcClientId: v)),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.settingsOidcSave),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Radio dot widget
// ---------------------------------------------------------------------------

class _RadioDot extends StatelessWidget {
  const _RadioDot({required this.selected, required this.cs});

  final bool selected;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 18,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? cs.primary : cs.outlineVariant,
            width: 2,
          ),
        ),
        child: selected
            ? Center(
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: cs.primary,
                  ),
                ),
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Proxy status dot (colored)
// ---------------------------------------------------------------------------

class _ProxyStatusDot extends StatelessWidget {
  const _ProxyStatusDot({required this.mode});

  final ProxyMode mode;

  @override
  Widget build(BuildContext context) {
    final color = mode == ProxyMode.none
        ? ColorSchemes.valid
        : ColorSchemes.accent;
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Proxy dialog
// ---------------------------------------------------------------------------

class _ProxyDialog extends ConsumerWidget {
  const _ProxyDialog({
    required this.proxyHost,
    required this.proxyPort,
    required this.proxyUser,
    required this.proxyPass,
  });

  final TextEditingController proxyHost;
  final TextEditingController proxyPort;
  final TextEditingController proxyUser;
  final TextEditingController proxyPass;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final l10n = AppLocalizations.of(context);

    return AlertDialog(
      icon: const Icon(Icons.wifi_outlined),
      title: Text(l10n.settingsProxy),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<int>(
              segments: [
                ButtonSegment(value: 0, label: Text(l10n.settingsNoProxy)),
                ButtonSegment(value: 1, label: Text(l10n.settingsSystemProxy)),
                ButtonSegment(value: 2, label: Text(l10n.settingsManualProxy)),
              ],
              selected: {settings.proxyConfig.mode.index},
              onSelectionChanged: (v) =>
                  ref.read(settingsProvider.notifier).update(
                      (s) => s.copyWith(
                          proxyConfig: s.proxyConfig.copyWith(
                              mode: ProxyMode.values[v.first]))),
            ),
            if (settings.proxyConfig.mode == ProxyMode.manual) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<ProxyType>(
                initialValue: settings.proxyConfig.type,
                decoration: InputDecoration(labelText: l10n.settingsProxyType),
                items: ProxyType.values
                    .map((t) => DropdownMenuItem(
                        value: t,
                        child: Text(t.name.toUpperCase())))
                    .toList(),
                onChanged: (v) =>
                    ref.read(settingsProvider.notifier).update(
                        (s) => s.copyWith(
                            proxyConfig: s.proxyConfig.copyWith(
                                type: v ?? ProxyType.http))),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: proxyHost,
                decoration: InputDecoration(labelText: l10n.settingsProxyHost),
                onChanged: (v) => ref
                    .read(settingsProvider.notifier)
                    .update((s) => s.copyWith(
                        proxyConfig: s.proxyConfig.copyWith(host: v))),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: proxyPort,
                decoration: InputDecoration(labelText: l10n.settingsProxyPort),
                keyboardType: TextInputType.number,
                onChanged: (v) => ref
                    .read(settingsProvider.notifier)
                    .update((s) => s.copyWith(
                        proxyConfig: s.proxyConfig.copyWith(
                            port: int.tryParse(v) ?? 0))),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: proxyUser,
                decoration:
                    InputDecoration(labelText: l10n.settingsProxyUsername),
                onChanged: (v) => ref
                    .read(settingsProvider.notifier)
                    .update((s) => s.copyWith(
                        proxyConfig:
                            s.proxyConfig.copyWith(username: v))),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: proxyPass,
                obscureText: true,
                decoration:
                    InputDecoration(labelText: l10n.settingsProxyPassword),
                onChanged: (v) => ref
                    .read(settingsProvider.notifier)
                    .update((s) => s.copyWith(
                        proxyConfig:
                            s.proxyConfig.copyWith(password: v))),
              ),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonClose),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Link tile
// ---------------------------------------------------------------------------

class _LinkTile extends StatelessWidget {
  const _LinkTile({
    required this.icon,
    required this.label,
    required this.url,
    required this.cs,
  });

  final IconData icon;
  final String label;
  final String url;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => launchUrl(Uri.parse(url)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: cs.primary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(fontFamily: 'Inter', 
                color: cs.primary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                decoration: TextDecoration.underline,
                decorationColor: cs.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
