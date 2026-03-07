// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/l10n/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../models/signature_options.dart';
import '../../providers/batch_sign_provider.dart';
import '../../providers/recent_files_provider.dart';
import '../../services/batch_sign/batch_sign_models.dart';
import '../../widgets/oc_gradient_button.dart';
import '../../widgets/pin_entry_dialog.dart';

/// Batch signing page.
class BatchSignPage extends ConsumerStatefulWidget {
  const BatchSignPage({super.key});

  @override
  ConsumerState<BatchSignPage> createState() => _BatchSignPageState();
}

class _BatchSignPageState extends ConsumerState<BatchSignPage> {
  bool _isDragging = false;
  final SignatureFormat _selectedFormat = SignatureFormat.pades;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(batchSignProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.batchSignTitle),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(
        children: [
          // File list area
          Expanded(
            child: state.items.isEmpty
                ? _buildEmptyState(context, l10n)
                : _buildFileList(context, l10n, state),
          ),
          // Bottom action bar
          _buildActionBar(context, l10n, state),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, AppLocalizations l10n) {
    final cs = Theme.of(context).colorScheme;

    return DropTarget(
      onDragDone: (detail) {
        _handleDroppedFiles(detail.files.map((f) => f.path).toList());
      },
      onDragEntered: (detail) {
        setState(() => _isDragging = true);
      },
      onDragExited: (detail) {
        setState(() => _isDragging = false);
      },
      child: Container(
        color: _isDragging ? cs.surfaceContainerHigh : Colors.transparent,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.cloud_upload_outlined, size: 64, color: cs.primary),
              const SizedBox(height: 16),
              Text(
                l10n.batchSignAddFiles,
                style: AppTheme.displayBold(cs).copyWith(fontSize: 20),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                l10n.signDropZoneHint,
                style: TextStyle(color: cs.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _pickFiles,
                icon: const Icon(Icons.add),
                label: Text(l10n.signDropZoneButton),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFileList(
    BuildContext context,
    AppLocalizations l10n,
    BatchSignState state,
  ) {
    final cs = Theme.of(context).colorScheme;

    return DropTarget(
      onDragDone: (detail) {
        _handleDroppedFiles(detail.files.map((f) => f.path).toList());
      },
      onDragEntered: (detail) {
        setState(() => _isDragging = true);
      },
      onDragExited: (detail) {
        setState(() => _isDragging = false);
      },
      child: Container(
        color: _isDragging ? cs.surfaceContainerHigh : Colors.transparent,
        child: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: state.items.length,
          itemBuilder: (context, index) {
            final item = state.items[index];
            return _buildFileCard(context, l10n, item, index, state.isRunning);
          },
        ),
      ),
    );
  }

  Widget _buildFileCard(
    BuildContext context,
    AppLocalizations l10n,
    BatchSignItem item,
    int index,
    bool isRunning,
  ) {
    final cs = Theme.of(context).colorScheme;
    final fileName = p.basename(item.inputPath);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fileName,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Chip(
                            label: Text(item.format.displayName),
                            visualDensity: VisualDensity.compact,
                          ),
                          const SizedBox(width: 8),
                          _buildStatusIcon(item.status, cs),
                        ],
                      ),
                    ],
                  ),
                ),
                if (!isRunning)
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      ref.read(batchSignProvider.notifier).removeAt(index);
                    },
                    iconSize: 20,
                  ),
              ],
            ),
            if (item.status == BatchSignItemStatus.signing)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(value: item.progress),
                    if (item.message != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          item.message!,
                          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            if (item.status == BatchSignItemStatus.failed && item.message != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  item.message!,
                  style: TextStyle(fontSize: 12, color: cs.error),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIcon(BatchSignItemStatus status, ColorScheme cs) {
    switch (status) {
      case BatchSignItemStatus.pending:
        return Icon(Icons.schedule, size: 20, color: cs.onSurfaceVariant);
      case BatchSignItemStatus.signing:
        return SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
        );
      case BatchSignItemStatus.success:
        return Icon(Icons.check_circle, size: 20, color: cs.primary);
      case BatchSignItemStatus.failed:
        return Icon(Icons.error, size: 20, color: cs.error);
      case BatchSignItemStatus.skipped:
        return Icon(Icons.remove_circle, size: 20, color: cs.onSurfaceVariant);
      case BatchSignItemStatus.cancelled:
        return Icon(Icons.cancel, size: 20, color: cs.onSurfaceVariant);
    }
  }

  Widget _buildActionBar(
    BuildContext context,
    AppLocalizations l10n,
    BatchSignState state,
  ) {
    final cs = Theme.of(context).colorScheme;

    if (state.isRunning) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          border: Border(top: BorderSide(color: cs.outlineVariant)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LinearProgressIndicator(value: state.overallProgress),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.batchSignInProgress(state.currentIndex + 1, state.totalCount),
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
                ElevatedButton(
                  onPressed: () {
                    ref.read(batchSignProvider.notifier).cancel();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: cs.error,
                    foregroundColor: cs.onError,
                  ),
                  child: Text(l10n.batchSignCancel),
                ),
              ],
            ),
          ],
        ),
      );
    }

    if (state.items.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          border: Border(top: BorderSide(color: cs.outlineVariant)),
        ),
        child: OcGradientButton(
          onPressed: null,
          label: l10n.batchSignStart,
        ),
      );
    }

    if (state.successCount > 0 || state.failedCount > 0 || state.skippedCount > 0) {
      // Completed state
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          border: Border(top: BorderSide(color: cs.outlineVariant)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.batchSignSummary(state.successCount, state.failedCount, state.skippedCount),
              style: const TextStyle(fontWeight: FontWeight.w500),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      ref.read(batchSignProvider.notifier).clear();
                    },
                    child: Text(l10n.batchSignCancel),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OcGradientButton(
                    onPressed: _pickFiles,
                    label: l10n.batchSignAddFiles,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    // Idle state with items
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickFiles,
                  icon: const Icon(Icons.add),
                  label: Text(l10n.batchSignAddFiles),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OcGradientButton(
                  onPressed: () => _startSigning(context, l10n),
                  label: l10n.batchSignStart,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.any,
    );

    if (result != null) {
      _handleDroppedFiles(result.paths.whereType<String>().toList());
    }
  }

  void _handleDroppedFiles(List<String> paths) {
    setState(() => _isDragging = false);
    ref.read(batchSignProvider.notifier).addFiles(paths, _selectedFormat);
  }

  Future<void> _startSigning(BuildContext context, AppLocalizations l10n) async {
    final pin = await PinEntryDialog.show(context);
    if (pin == null || !mounted) return;

    // Start signing with empty PAN (can be extended if needed)
    await ref.read(batchSignProvider.notifier).start(
          pin: pin,
          pan: '',
        );

    // Add signed files to recent files
    final state = ref.read(batchSignProvider);
    for (final item in state.items) {
      if (item.status == BatchSignItemStatus.success) {
        ref.read(recentSignedFilesProvider.notifier).add(item.inputPath);
      }
    }
  }
}
