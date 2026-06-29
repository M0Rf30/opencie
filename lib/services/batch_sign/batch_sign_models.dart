// SPDX-License-Identifier: GPL-3.0-or-later

import '../../models/signature_options.dart';

enum BatchSignItemStatus {
  pending,
  signing,
  success,
  failed,
  skipped,
  cancelled,
}

class BatchSignItem {
  final String inputPath;
  final SignatureFormat format;
  final BatchSignItemStatus status;
  final double progress; // 0.0..1.0 for current item
  final String? message; // last progress message OR error
  final String? outputPath; // when success
  final int? errorCode; // CieResult.returnValue when failed

  const BatchSignItem({
    required this.inputPath,
    required this.format,
    this.status = BatchSignItemStatus.pending,
    this.progress = 0.0,
    this.message,
    this.outputPath,
    this.errorCode,
  });

  BatchSignItem copyWith({
    String? inputPath,
    SignatureFormat? format,
    BatchSignItemStatus? status,
    double? progress,
    String? message,
    String? outputPath,
    int? errorCode,
  }) {
    return BatchSignItem(
      inputPath: inputPath ?? this.inputPath,
      format: format ?? this.format,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      message: message ?? this.message,
      outputPath: outputPath ?? this.outputPath,
      errorCode: errorCode ?? this.errorCode,
    );
  }
}

class BatchSignState {
  final List<BatchSignItem> items;
  final int currentIndex; // -1 when not running
  final bool isRunning;
  final bool isCancelled;

  const BatchSignState({
    this.items = const [],
    this.currentIndex = -1,
    this.isRunning = false,
    this.isCancelled = false,
  });

  int get successCount =>
      items.where((i) => i.status == BatchSignItemStatus.success).length;
  int get failedCount =>
      items.where((i) => i.status == BatchSignItemStatus.failed).length;
  int get skippedCount =>
      items.where((i) => i.status == BatchSignItemStatus.skipped).length;
  int get cancelledCount =>
      items.where((i) => i.status == BatchSignItemStatus.cancelled).length;
  int get totalCount => items.length;

  double get overallProgress {
    if (totalCount == 0) return 0.0;
    final completed = items
        .where(
          (i) =>
              i.status == BatchSignItemStatus.success ||
              i.status == BatchSignItemStatus.failed ||
              i.status == BatchSignItemStatus.skipped ||
              i.status == BatchSignItemStatus.cancelled,
        )
        .length;
    final currentProgress = currentIndex >= 0 && currentIndex < items.length
        ? items[currentIndex].progress
        : 0.0;
    return (completed + currentProgress) / totalCount;
  }

  BatchSignState copyWith({
    List<BatchSignItem>? items,
    int? currentIndex,
    bool? isRunning,
    bool? isCancelled,
  }) {
    return BatchSignState(
      items: items ?? this.items,
      currentIndex: currentIndex ?? this.currentIndex,
      isRunning: isRunning ?? this.isRunning,
      isCancelled: isCancelled ?? this.isCancelled,
    );
  }
}
