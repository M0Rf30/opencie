// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../../core/l10n/app_localizations.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/color_schemes.dart';
import '../../../models/signature_options.dart';
import '../../../widgets/oc_file_tile.dart';
import '../../../widgets/oc_gradient_button.dart';
import '../../../widgets/oc_section_label.dart';
import '../../../widgets/oc_status_disc.dart';

/// Success dialog shown after a document is signed.
///
/// [outputPath] is the full path of the signed file.
/// [options] are the signature options used for the signing operation.
/// [onOpenFile] is called when the user presses "Open"; receives [outputPath].
/// [onVerifyFile] is called when the user presses "Verify"; receives [outputPath].
class SignedResultDialog extends StatelessWidget {
  const SignedResultDialog({
    super.key,
    required this.outputPath,
    required this.options,
    required this.onOpenFile,
    required this.onVerifyFile,
  });

  final String outputPath;
  final SignatureOptions options;
  final Future<void> Function(String path) onOpenFile;
  final void Function(String path) onVerifyFile;

  @override
  Widget build(BuildContext context) {
    final fileName = outputPath.split('/').last;
    final ext = fileName.split('.').last.toLowerCase();
    final folderPath = outputPath.contains('/')
        ? outputPath.substring(0, outputPath.lastIndexOf('/'))
        : '/OpenCIE';
    final folderLabel = folderPath.split('/').last;
    final now = DateTime.now();
    final dateLabel =
        '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';

    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      backgroundColor: cs.surfaceContainer,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Success disc + halo
            SizedBox(
              width: 140,
              height: 140,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  OcDiscHalo(size: 120, color: ColorSchemes.valid),
                  OcStatusDisc(
                    tone: OcStatusTone.valid,
                    icon: const Icon(
                      Icons.check_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                    size: 92,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Title
            Text(
              l10n.signSuccessTitle,
              style: AppTheme.displayBold(cs),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),

            // Format mono subtitle
            OcMonoText(
              '${options.format.displayName.split(' ').first}${options.addTimestamp ? ' · TSA' : ''}',
              color: cs.onSurfaceVariant,
              fontSize: 12,
            ),
            const SizedBox(height: 18),

            // File chip
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: cs.outlineVariant),
              ),
              child: Row(
                children: [
                  OcFileTile(extension: ext, width: 32, height: 38),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          fileName,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            color: cs.onSurface,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        OcMonoText(
                          'Salvato in /$folderLabel',
                          color: cs.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.open_in_new_rounded, size: 16, color: cs.primary),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Diagnostics block
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: cs.outlineVariant),
              ),
              child: Column(
                children: [
                  _DiagRow(label: 'firmato il', value: dateLabel),
                  _DiagRow(
                    label: 'formato',
                    value: options.format.displayName.split(' ').first,
                  ),
                  _DiagRow(
                    label: 'tsa',
                    value: options.addTimestamp ? 'FreeTSA · RFC 3161' : '—',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),

            // Action buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      onVerifyFile(outputPath);
                    },
                    icon: const Icon(Icons.verified_user_rounded, size: 16),
                    label: Text(l10n.signVerifyButton),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: OcGradientButton(
                    label: l10n.signOpenButton,
                    icon: Icons.open_in_new_rounded,
                    onPressed: () {
                      Navigator.pop(context);
                      onOpenFile(outputPath);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Diagnostic key–value row in the success dialog.
class _DiagRow extends StatelessWidget {
  const _DiagRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: AppTheme.monoBody(
                cs,
                color: cs.onSurfaceVariant,
              ).copyWith(fontSize: 11),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: AppTheme.monoBody(cs).copyWith(fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
