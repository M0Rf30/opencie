// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:url_launcher/url_launcher.dart';

import '../../core/l10n/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/color_schemes.dart';
import '../app_lock/app_lock_settings_section.dart';
import '../../models/proxy_config.dart';
import '../../models/signature_options.dart';
import '../../models/tsa_config.dart';
import '../../providers/settings_provider.dart';
import '../../services/storage_service.dart';
import '../../services/update_checker.dart';
import '../../widgets/oc_action_row.dart';
import '../../widgets/oc_help_sheet.dart';
import '../../widgets/oc_mark.dart'; // used in About section
import '../../widgets/oc_page.dart';
import '../../widgets/oc_section_label.dart';
import '../../widgets/update_notice.dart';

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

  // App version string, sourced from the platform bundle (populated from
  // pubspec.yaml at build time). Falls back to the license-only label until
  // the async lookup completes.
  String _versionLabel = 'OpenCIE · GPL-3.0';

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _proxyHost.text = settings.proxyConfig.host;
    _proxyPort.text = settings.proxyConfig.port == 0
        ? ''
        : settings.proxyConfig.port.toString();
    _proxyUser.text = settings.proxyConfig.username;
    _proxyPass.text = settings.proxyConfig.password;
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() {
      _versionLabel = 'OpenCIE ${info.version}+${info.buildNumber} · GPL-3.0';
    });
  }

  @override
  void dispose() {
    _proxyHost.dispose();
    _proxyPort.dispose();
    _proxyUser.dispose();
    _proxyPass.dispose();
    super.dispose();
  }

  void _showProxyDialog() {
    final settings = ref.read(settingsProvider);
    // Sync controllers with current state
    _proxyHost.text = settings.proxyConfig.host;
    _proxyPort.text = settings.proxyConfig.port == 0
        ? ''
        : settings.proxyConfig.port.toString();
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

  /// Settings is a form: keep rows readable on wide windows.
  static const double _maxWidth = 760;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final settings = ref.watch(settingsProvider);
    final l10n = AppLocalizations.of(context);

    // TSA providers: FreeTSA + qualified Italian TSPs
    final tsaEntries = tsaProviderEntries();

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // ── Page heading ─────────────────────────────────────────────────
          OcPageBody.sliver(
            maxWidth: _maxWidth,
            child: SliverToBoxAdapter(
              child: OcPageHeader(
                title: l10n.settingsTitle,
                subtitle: l10n.settingsSubtitle,
                actions: [
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
                          OcHelpStep(
                            title: l10n.helpSettingsStep1Title,
                            body: l10n.helpSettingsStep1Body,
                            icon: Icons.draw_rounded,
                          ),
                          OcHelpStep(
                            title: l10n.helpSettingsStep2Title,
                            body: l10n.helpSettingsStep2Body,
                            icon: Icons.schedule_rounded,
                          ),
                          OcHelpStep(
                            title: l10n.helpSettingsStep3Title,
                            body: l10n.helpSettingsStep3Body,
                            icon: Icons.security_rounded,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),

          if (settings.secureStorageUnavailable)
            OcPageBody.sliver(
              maxWidth: _maxWidth,
              child: SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Card(
                    color: cs.tertiaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            color: cs.onTertiaryContainer,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              l10n.secureStorageUnavailableWarning,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: cs.onTertiaryContainer),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 4)),

          OcPageBody.sliver(
            maxWidth: _maxWidth,
            child: SliverList(
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
                    // Language row
                    OcActionRow(
                      leadingIcon: Icons.language_outlined,
                      title: l10n.settingsLanguageTitle,
                      subtitle: _languageLabel(settings.languageCode, l10n),
                      onTap: () => _showLanguageDialog(context, ref, l10n),
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

                // ── Security (app lock) ──────────────────────────────────
                const AppLockSettingsSection(),

                // ── 1. AUTORITÀ DI MARCATURA (TSA) ────────────────────────
                OcSectionLabel(l10n.settingsTsa),
                const SizedBox(height: 8),
                OcGroupCard(
                  children: tsaEntries.map((entry) {
                    final isSelected =
                        settings.tsaConfig.serverUrl == entry.value;
                    return OcActionRow(
                      leading: _RadioDot(selected: isSelected, cs: cs),
                      selected: isSelected,
                      title: entry.key,
                      subtitle: entry.value,
                      subtitleMono: true,
                      onTap: () => ref
                          .read(settingsProvider.notifier)
                          .update(
                            (s) => s.copyWith(
                              tsaConfig: s.tsaConfig.copyWith(
                                serverUrl: entry.value,
                              ),
                            ),
                          ),
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
                      subtitle:
                          settings.destinationFolder ??
                          l10n.settingsSameAsDocument,
                      subtitleMono: settings.destinationFolder != null,
                      trailing: settings.destinationFolder != null
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                    color: cs.onSurfaceVariant,
                                  ),
                                  tooltip: l10n.commonClear,
                                  onPressed: () => ref
                                      .read(settingsProvider.notifier)
                                      .clearDestinationFolder(),
                                ),
                                Icon(
                                  Icons.chevron_right_rounded,
                                  color: cs.onSurfaceVariant,
                                  size: 22,
                                ),
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
                          ref
                              .read(settingsProvider.notifier)
                              .update(
                                (s) => s.copyWith(destinationFolder: picked),
                              );
                        }
                      },
                    ),
                    OcActionRow(
                      title: l10n.settingsOpenAfterSign,
                      trailing: Switch.adaptive(
                        value: settings.openFolderAfterSign,
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
                        .where(
                          (f) =>
                              f == SignatureFormat.pades ||
                              f == SignatureFormat.cades,
                        )
                        .map((f) {
                          final isSelected = settings.defaultPdfFormat == f;
                          return OcActionRow(
                            leading: _RadioDot(selected: isSelected, cs: cs),
                            selected: isSelected,
                            title: f.displayName,
                            subtitle: f == SignatureFormat.pades
                                ? l10n.settingsFormatPadesSubtitle
                                : l10n.settingsFormatCadesSubtitle,
                            onTap: () => ref
                                .read(settingsProvider.notifier)
                                .update((s) => s.copyWith(defaultPdfFormat: f)),
                          );
                        }),
                    OcActionRow(
                      title: l10n.settingsGraphicPades,
                      trailing: Switch.adaptive(
                        value: settings.graphicPades,
                        onChanged: (v) => ref
                            .read(settingsProvider.notifier)
                            .update((s) => s.copyWith(graphicPades: v)),
                      ),
                    ),
                    OcActionRow(
                      title: l10n.settingsAlwaysTimestamp,
                      trailing: Switch.adaptive(
                        value: settings.alwaysTimestamp,
                        onChanged: (v) => ref
                            .read(settingsProvider.notifier)
                            .update((s) => s.copyWith(alwaysTimestamp: v)),
                      ),
                    ),
                    if (settings.graphicPades) ...[
                      OcActionRow(
                        title: l10n.settingsEnableDate,
                        subtitle: l10n.settingsEnableDateSubtitle,
                        trailing: Switch.adaptive(
                          value: settings.includeDate,
                          onChanged: (v) => ref
                              .read(settingsProvider.notifier)
                              .update((s) => s.copyWith(includeDate: v)),
                        ),
                      ),
                    ],
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
                        cs: cs,
                      ),
                      selected:
                          settings.validationType == ValidationType.ocspOnly,
                      title: l10n.settingsOcspOnly,
                      onTap: () => ref
                          .read(settingsProvider.notifier)
                          .update(
                            (s) => s.copyWith(
                              validationType: ValidationType.ocspOnly,
                            ),
                          ),
                    ),
                    OcActionRow(
                      leading: _RadioDot(
                        selected:
                            settings.validationType == ValidationType.ocspFirst,
                        cs: cs,
                      ),
                      selected:
                          settings.validationType == ValidationType.ocspFirst,
                      title: l10n.settingsOcspFirst,
                      onTap: () => ref
                          .read(settingsProvider.notifier)
                          .update(
                            (s) => s.copyWith(
                              validationType: ValidationType.ocspFirst,
                            ),
                          ),
                    ),
                    OcActionRow(
                      leading: _RadioDot(
                        selected:
                            settings.validationType == ValidationType.crlOnly,
                        cs: cs,
                      ),
                      selected:
                          settings.validationType == ValidationType.crlOnly,
                      title: l10n.settingsCrlOnly,
                      onTap: () => ref
                          .read(settingsProvider.notifier)
                          .update(
                            (s) => s.copyWith(
                              validationType: ValidationType.crlOnly,
                            ),
                          ),
                    ),
                    OcActionRow(
                      leading: _RadioDot(
                        selected:
                            settings.validationType == ValidationType.crlFirst,
                        cs: cs,
                      ),
                      selected:
                          settings.validationType == ValidationType.crlFirst,
                      title: l10n.settingsCrlFirst,
                      onTap: () => ref
                          .read(settingsProvider.notifier)
                          .update(
                            (s) => s.copyWith(
                              validationType: ValidationType.crlFirst,
                            ),
                          ),
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
                      leading: _ProxyStatusDot(mode: settings.proxyConfig.mode),
                      title: l10n.settingsProxy,
                      subtitle: _proxySubtitle(settings.proxyConfig, l10n),
                      subtitleMono:
                          settings.proxyConfig.mode == ProxyMode.manual,
                      onTap: _showProxyDialog,
                    ),
                  ],
                ),

                const SizedBox(height: 20),

                // ── 8. ABOUT ──────────────────────────────────────────────
                OcSectionLabel(l10n.settingsAbout),
                const SizedBox(height: 8),

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
                            style: TextStyle(
                              fontFamily: 'Inter',
                              color: cs.primary,
                              fontWeight: FontWeight.w800,
                              fontSize: 17,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            l10n.settingsAboutDescription,
                            style: TextStyle(
                              fontFamily: 'Inter',
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
                                url: 'https://github.com/M0Rf30/opencie/issues',
                                cs: cs,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                OcGroupCard(
                  children: [
                    OcActionRow(
                      leadingIcon: Icons.system_update_alt,
                      title: l10n.settingsCheckForUpdates,
                      subtitle: l10n.settingsCheckForUpdatesSubtitle,
                      trailing: Switch.adaptive(
                        value: settings.checkForUpdates,
                        onChanged: (v) => ref
                            .read(settingsProvider.notifier)
                            .update(
                              (s) => s.copyWith(
                                checkForUpdates: v,
                                updateCheckConsentAsked: true,
                              ),
                            ),
                      ),
                    ),
                    OcActionRow(
                      leadingIcon: Icons.refresh,
                      title: l10n.settingsCheckForUpdatesNow,
                      subtitle: _checkingUpdates
                          ? l10n.settingsUpdateChecking
                          : null,
                      onTap: _checkingUpdates ? null : _checkUpdatesNow,
                    ),
                  ],
                ),

                const SizedBox(height: 20),

                // ── Footer ────────────────────────────────────────────────
                Center(
                  child: Text(
                    _versionLabel,
                    style: AppTheme.monoCaption(
                      cs,
                      color: cs.onSurfaceVariant.withValues(alpha: 0.5),
                    ),
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

  bool _checkingUpdates = false;

  Future<void> _checkUpdatesNow() async {
    setState(() => _checkingUpdates = true);
    final result = await ManualCheck.run();
    if (!mounted) return;
    setState(() => _checkingUpdates = false);
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    switch (result.status) {
      case ManualCheckStatus.available:
        showUpdateBanner(messenger, l10n, result.info!, recordDismissal: false);
      case ManualCheckStatus.upToDate:
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.settingsUpdateUpToDate)),
        );
      case ManualCheckStatus.failed:
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.settingsUpdateFailed)),
        );
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

  String _languageLabel(String? code, AppLocalizations l10n) {
    switch (code) {
      case 'it':
        return 'Italiano';
      case 'en':
        return 'English';
      default:
        return l10n.settingsLanguageSystem;
    }
  }

  void _showLanguageDialog(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) {
    const systemValue = 'system';
    final settings = ref.read(settingsProvider);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.settingsLanguageTitle),
        content: RadioGroup<String>(
          groupValue: settings.languageCode ?? systemValue,
          onChanged: (value) {
            if (value == null) return;
            ref
                .read(settingsProvider.notifier)
                .update(
                  (s) => s.copyWith(
                    languageCode: value == systemValue ? null : value,
                  ),
                );
            Navigator.pop(ctx);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<String>(
                title: Text(l10n.settingsLanguageSystem),
                value: systemValue,
              ),
              const RadioListTile<String>(title: Text('Italiano'), value: 'it'),
              const RadioListTile<String>(title: Text('English'), value: 'en'),
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
                .map(
                  (scale) => RadioListTile<double>(
                    title: Text('${(scale * 100).round()}%'),
                    value: scale,
                  ),
                )
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
            color: selected ? cs.primary : cs.outline,
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
    final cs = Theme.of(context).colorScheme;
    final color = mode == ProxyMode.none ? cs.valid : cs.tertiary;
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
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
              onSelectionChanged: (v) => ref
                  .read(settingsProvider.notifier)
                  .update(
                    (s) => s.copyWith(
                      proxyConfig: s.proxyConfig.copyWith(
                        mode: ProxyMode.values[v.first],
                      ),
                    ),
                  ),
            ),
            if (settings.proxyConfig.mode == ProxyMode.manual) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<ProxyType>(
                initialValue: settings.proxyConfig.type,
                decoration: InputDecoration(labelText: l10n.settingsProxyType),
                items: ProxyType.values
                    .map(
                      (t) => DropdownMenuItem(
                        value: t,
                        child: Text(t.name.toUpperCase()),
                      ),
                    )
                    .toList(),
                onChanged: (v) => ref
                    .read(settingsProvider.notifier)
                    .update(
                      (s) => s.copyWith(
                        proxyConfig: s.proxyConfig.copyWith(
                          type: v ?? ProxyType.http,
                        ),
                      ),
                    ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: proxyHost,
                decoration: InputDecoration(labelText: l10n.settingsProxyHost),
                onChanged: (v) => ref
                    .read(settingsProvider.notifier)
                    .update(
                      (s) => s.copyWith(
                        proxyConfig: s.proxyConfig.copyWith(host: v),
                      ),
                    ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: proxyPort,
                decoration: InputDecoration(labelText: l10n.settingsProxyPort),
                keyboardType: TextInputType.number,
                onChanged: (v) => ref
                    .read(settingsProvider.notifier)
                    .update(
                      (s) => s.copyWith(
                        proxyConfig: s.proxyConfig.copyWith(
                          port: int.tryParse(v) ?? 0,
                        ),
                      ),
                    ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: proxyUser,
                decoration: InputDecoration(
                  labelText: l10n.settingsProxyUsername,
                ),
                onChanged: (v) => ref
                    .read(settingsProvider.notifier)
                    .update(
                      (s) => s.copyWith(
                        proxyConfig: s.proxyConfig.copyWith(username: v),
                      ),
                    ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: proxyPass,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: l10n.settingsProxyPassword,
                ),
                onChanged: (v) => ref
                    .read(settingsProvider.notifier)
                    .update(
                      (s) => s.copyWith(
                        proxyConfig: s.proxyConfig.copyWith(password: v),
                      ),
                    ),
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
              style: TextStyle(
                fontFamily: 'Inter',
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
