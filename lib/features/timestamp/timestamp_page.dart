// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n/app_localizations.dart';
import '../../ffi/opencie_pkcs11.dart';
import '../../models/tsa_config.dart';
import '../../widgets/oc_action_row.dart';
import '../../widgets/oc_help_sheet.dart';
import '../../widgets/oc_page.dart';
import '../../providers/settings_provider.dart';
import '../sign/widgets/document_drop_zone.dart';

class TimestampPage extends ConsumerStatefulWidget {
  const TimestampPage({super.key});

  @override
  ConsumerState<TimestampPage> createState() => _TimestampPageState();
}

class _TimestampPageState extends ConsumerState<TimestampPage> {
  final List<String> _selectedFiles = [];
  bool _isTimestamping = false;

  void _onFilesSelected(List<String> paths) {
    setState(() => _selectedFiles.addAll(paths));
  }

  void _onFileRemoved(String path) {
    setState(() => _selectedFiles.remove(path));
  }

  Future<void> _applyTimestamp() async {
    if (_selectedFiles.isEmpty || _isTimestamping) return;
    final l10n = AppLocalizations.of(context);
    final settings = ref.read(settingsProvider);

    setState(() => _isTimestamping = true);

    final files = List<String>.of(_selectedFiles);
    final total = files.length;
    // 0-based index of the file currently being timestamped, driving the
    // "i/N" title of the single batch-wide progress dialog below.
    final progressNotifier = ValueNotifier<int>(0);
    var dialogOpen = false;

    if (mounted) {
      dialogOpen = true;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => ValueListenableBuilder<int>(
          valueListenable: progressNotifier,
          builder: (context, current, _) => AlertDialog(
            title: Text(
              total > 1
                  ? l10n.timestampProgress(current + 1, total)
                  : l10n.cieProgressTimestamping,
            ),
            content: const SizedBox(
              height: 100,
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
        ),
      ).whenComplete(() => dialogOpen = false);
    }

    try {
      for (var i = 0; i < files.length; i++) {
        progressNotifier.value = i;
        final file = files[i];
        try {
          final result = await OpenCiePkcs11.instance.timestamp(
            inputPath: file,
            tsaUrl: settings.tsaConfig.serverUrl,
            tsaUsername: settings.tsaConfig.username.isEmpty
                ? null
                : settings.tsaConfig.username,
            tsaPassword: settings.tsaConfig.password.isEmpty
                ? null
                : settings.tsaConfig.password,
            outputPath: '$file.tsr',
          );

          if (!mounted) return;
          if (result.isSuccess) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(l10n.timestampSuccess),
                behavior: SnackBarBehavior.floating,
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  l10n.timestampFailed(
                    '0x${result.returnValue.toUnsigned(32).toRadixString(16)}',
                  ),
                ),
                behavior: SnackBarBehavior.floating,
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
            );
          }
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.timestampFailed(e.toString())),
              behavior: SnackBarBehavior.floating,
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
      }
    } finally {
      if (dialogOpen && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      progressNotifier.dispose();
      if (mounted) setState(() => _isTimestamping = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final tsa = ref.watch(settingsProvider.select((s) => s.tsaConfig));

    Widget body(Widget child) =>
        OcPageBody.sliver(child: SliverToBoxAdapter(child: child));

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // ── Page heading ─────────────────────────────────────────────────
          body(
            OcPageHeader(
              title: l10n.timestampTitle,
              subtitle: l10n.timestampSubtitleFull,
              actions: [
                IconButton(
                  icon: const Icon(Icons.info_outline_rounded),
                  tooltip: l10n.helpButtonTooltip,
                  onPressed: () => OcHelpSheet.show(
                    context,
                    OcHelpSheet(
                      title: l10n.helpTimestampTitle,
                      icon: Icons.schedule_rounded,
                      iconColor: cs.secondary,
                      steps: [
                        OcHelpStep(
                          title: l10n.helpTimestampStep1Title,
                          body: l10n.helpTimestampStep1Body,
                          icon: Icons.folder_open_rounded,
                        ),
                        OcHelpStep(
                          title: l10n.helpTimestampStep2Title,
                          body: l10n.helpTimestampStep2Body,
                          icon: Icons.settings_rounded,
                        ),
                        OcHelpStep(
                          title: l10n.helpTimestampStep3Title,
                          body: l10n.helpTimestampStep3Body,
                          icon: Icons.verified_rounded,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),

          // Warning banner: only for the non-qualified FreeTSA default
          if (tsa.isFreeTsa)
            body(
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Card(
                  key: const ValueKey('timestampFreeTsaWarning'),
                  color: theme.colorScheme.tertiaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          color: theme.colorScheme.onTertiaryContainer,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            l10n.timestampWarningNote,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onTertiaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // TSA info
          body(
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: OcGroupCard(
                children: [
                  OcActionRow(
                    leadingIcon: Icons.dns_outlined,
                    title: l10n.timestampTsaServerLabel,
                    subtitle:
                        '${tsaDisplayName(tsa.serverUrl)} · ${tsa.serverUrl}',
                    subtitleMono: true,
                    trailing: OutlinedButton(
                      key: const ValueKey('timestampConfigure'),
                      onPressed: () => context.go('/settings'),
                      child: Text(l10n.timestampConfigureButton),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Drop zone
          body(
            DocumentDropZone(
              selectedFiles: _selectedFiles,
              onFilesSelected: _onFilesSelected,
              onFileRemoved: _onFileRemoved,
              hintText: l10n.timestampDropZoneHint,
            ),
          ),

          // Action bar
          if (_selectedFiles.isNotEmpty)
            body(
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Card(
                  color: cs.secondaryContainer.withValues(alpha: 0.3),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 20,
                          color: cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _selectedFiles.length > 1
                                ? l10n.timestampFilesInfoPlural(
                                    _selectedFiles.length,
                                  )
                                : l10n.timestampFilesInfo(1),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: _isTimestamping ? null : _applyTimestamp,
                          icon: const Icon(Icons.schedule),
                          label: Text(l10n.timestampApplyButton),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}
