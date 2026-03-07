// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:desktop_drop/desktop_drop.dart';
import 'package:dotted_border/dotted_border.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../core/l10n/app_localizations.dart';

/// Drag-and-drop zone for document selection.
///
/// Shared by Sign, Verify, Timestamp, Encrypt, and Decrypt pages.
class DocumentDropZone extends StatefulWidget {
  const DocumentDropZone({
    required this.selectedFiles,
    required this.onFilesSelected,
    required this.onFileRemoved,
    this.hintText = 'Drag & drop files here',
    this.acceptedExtensions,
    super.key,
  });

  final List<String> selectedFiles;
  final ValueChanged<List<String>> onFilesSelected;
  final ValueChanged<String> onFileRemoved;
  final String hintText;
  final List<String>? acceptedExtensions;

  @override
  State<DocumentDropZone> createState() => _DocumentDropZoneState();
}

class _DocumentDropZoneState extends State<DocumentDropZone> {
  bool _isDragging = false;

  Future<void> _pickFiles() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      type: widget.acceptedExtensions != null ? FileType.custom : FileType.any,
      allowedExtensions: widget.acceptedExtensions,
    );
    if (result != null) {
      widget.onFilesSelected(
        result.paths.whereType<String>().toList(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final hasFiles = widget.selectedFiles.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Drop zone
        DropTarget(
          onDragEntered: (_) => setState(() => _isDragging = true),
          onDragExited: (_) => setState(() => _isDragging = false),
          onDragDone: (details) {
            setState(() => _isDragging = false);
            widget.onFilesSelected(
              details.files.map((f) => f.path).toList(),
            );
          },
          child: GestureDetector(
            onTap: _pickFiles,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              child: DottedBorder(
                options: RoundedRectDottedBorderOptions(
                  radius: const Radius.circular(18),
                  dashPattern: const [8, 4],
                  color: _isDragging ? cs.primary : cs.outline,
                  strokeWidth: _isDragging ? 2.0 : 1.5,
                ),
                child: Container(
                  width: double.infinity,
                  padding: EdgeInsets.symmetric(
                    vertical: hasFiles ? 24 : 48,
                    horizontal: 24,
                  ),
                  decoration: BoxDecoration(
                    color: _isDragging
                        ? cs.primary.withValues(alpha: 0.06)
                        : cs.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        child: Icon(
                          _isDragging
                              ? Icons.file_download_rounded
                              : Icons.cloud_upload_outlined,
                          key: ValueKey(_isDragging),
                          size: hasFiles ? 30 : 44,
                          color: _isDragging
                              ? cs.primary
                              : cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        widget.hintText,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        onPressed: _pickFiles,
                        icon: const Icon(Icons.folder_open_rounded, size: 16),
                        label: Text(l10n.commonSelectFiles),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),

        // File list
        if (hasFiles) ...[
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: cs.surfaceContainer,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: cs.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: widget.selectedFiles.length,
              separatorBuilder: (context, index) =>
                  Divider(height: 1, color: cs.outlineVariant),
              itemBuilder: (context, index) {
                final path = widget.selectedFiles[index];
                final name = path.split('/').last.split('\\').last;
                return ListTile(
                  dense: true,
                  leading: _fileIcon(name, cs),
                  title: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  subtitle: Text(
                    path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => widget.onFileRemoved(path),
                    tooltip: l10n.commonDelete,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _fileIcon(String name, ColorScheme cs) {
    final ext = name.split('.').last.toLowerCase();
    final (IconData icon, Color color) = switch (ext) {
      'pdf' => (Icons.picture_as_pdf, const Color(0xFFE53935)),
      'p7m' => (Icons.enhanced_encryption, const Color(0xFF1E88E5)),
      'p7e' => (Icons.lock, const Color(0xFF9C27B0)),
      'xml' => (Icons.code, const Color(0xFFFB8C00)),
      'doc' || 'docx' => (Icons.description, const Color(0xFF42A5F5)),
      'xls' || 'xlsx' => (Icons.table_chart, const Color(0xFF43A047)),
      _ => (Icons.insert_drive_file, cs.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, color: color, size: 18),
    );
  }
}
