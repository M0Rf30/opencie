// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import 'pdf_models.dart';
import 'pdf_reader.dart';

/// Represents a new or updated object to be written in incremental update.
class _PdfObject {
  _PdfObject({
    required this.objNum,
    required this.gen,
    required this.body,
    this.streamBytes,
  });
  final int objNum;
  final int gen;
  final String body;  // dict entries, e.g. "/Type /DSS /Certs [...]"
  final Uint8List? streamBytes;  // if null, not a stream object
}

/// Helper to build incremental update bytes.
class PdfIncrementalWriter {
  PdfIncrementalWriter({required this.original, required this.trailer});
  final Uint8List original;
  final PdfTrailerInfo trailer;

  final List<_PdfObject> _objects = [];
  int _nextObjNum = 0;

  /// Initialize next object number based on trailer size.
  void _initNextObjNum() {
    if (_nextObjNum == 0) {
      _nextObjNum = trailer.size;
    }
  }

  /// Adds an indirect object. Returns its [PdfRef].
  PdfRef addObject(String body) {
    _initNextObjNum();
    final ref = PdfRef(_nextObjNum, 0);
    _objects.add(_PdfObject(objNum: _nextObjNum, gen: 0, body: body));
    _nextObjNum++;
    return ref;
  }

  /// Adds a stream object. Returns its [PdfRef].
  PdfRef addStreamObject(Map<String, String> dictEntries, Uint8List streamBytes) {
    _initNextObjNum();
    final ref = PdfRef(_nextObjNum, 0);

    // Build dict
    final dictBody = StringBuffer();
    dictBody.write('<<');
    for (final entry in dictEntries.entries) {
      dictBody.write(' ${entry.key} ${entry.value}');
    }
    dictBody.write(' /Length ${streamBytes.length} >>');

    _objects.add(
      _PdfObject(
        objNum: _nextObjNum,
        gen: 0,
        body: dictBody.toString(),
        streamBytes: streamBytes,
      ),
    );
    _nextObjNum++;
    return ref;
  }

  /// Updates an existing object. Returns its [PdfRef] (same num, same gen).
  PdfRef updateObject(PdfRef oldRef, String body) {
    _initNextObjNum();
    _objects.add(_PdfObject(objNum: oldRef.objNum, gen: oldRef.gen, body: body));
    return oldRef;
  }

  /// Finalizes the incremental update and returns the FULL new PDF bytes.
  Uint8List finalize({required PdfRef rootRef}) {
    if (_objects.isEmpty) {
      throw PadesException('No objects to write in incremental update');
    }

    final output = BytesBuilder();

    // Append original bytes
    output.add(original);

    // Ensure original ends with newline
    if (original.isNotEmpty && original.last != 0x0A && original.last != 0x0D) {
      output.addByte(0x0A);
    }

    // Track offsets for xref
    final objectOffsets = <int, int>{};

    // Write new/updated objects
    for (final obj in _objects) {
      objectOffsets[obj.objNum] = output.length;

      // "N G obj\n"
      output.add('${obj.objNum} ${obj.gen} obj\n'.codeUnits);

      // Dict body
      output.add(obj.body.codeUnits);
      output.addByte(0x0A); // newline

      // Stream if present
      if (obj.streamBytes != null) {
        output.add('stream\n'.codeUnits);
        output.add(obj.streamBytes!);
        output.add('\nendstream\n'.codeUnits);
      }

      output.add('endobj\n'.codeUnits);
    }

    // Write xref
    final xrefOffset = output.length;
    output.add('xref\n'.codeUnits);

    // Group objects by contiguous ranges
    final sortedObjNums = objectOffsets.keys.toList()..sort();
    final ranges = <({int start, int count})>[];

    if (sortedObjNums.isNotEmpty) {
      int rangeStart = sortedObjNums[0];
      int rangeCount = 1;

      for (int i = 1; i < sortedObjNums.length; i++) {
        if (sortedObjNums[i] == sortedObjNums[i - 1] + 1) {
          rangeCount++;
        } else {
          ranges.add((start: rangeStart, count: rangeCount));
          rangeStart = sortedObjNums[i];
          rangeCount = 1;
        }
      }
      ranges.add((start: rangeStart, count: rangeCount));
    }

    // Write xref subsections
    for (final range in ranges) {
      output.add('${range.start} ${range.count}\n'.codeUnits);

      for (int i = 0; i < range.count; i++) {
        final objNum = range.start + i;
        final offset = objectOffsets[objNum] ?? 0;

        // Format: "OOOOOOOOOO GGGGG n \n" (20 bytes total)
        final offsetStr = offset.toString().padLeft(10, '0');
        final genStr = '0'.padLeft(5, '0');
        output.add('$offsetStr $genStr n \n'.codeUnits);
      }
    }

    // Write trailer
    output.add('trailer\n'.codeUnits);
    output.add('<<'.codeUnits);
    output.add(' /Size $_nextObjNum'.codeUnits);
    output.add(' /Prev ${trailer.prevXrefOffset}'.codeUnits);
    output.add(' /Root ${rootRef.objNum} ${rootRef.gen} R'.codeUnits);

    if (trailer.id != null) {
      output.add(' /ID '.codeUnits);
      output.add(trailer.id!);
    }

    output.add('>>\n'.codeUnits);

    // Write startxref
    output.add('startxref\n'.codeUnits);
    output.add('$xrefOffset\n'.codeUnits);
    output.add('%%EOF\n'.codeUnits);

    return output.toBytes();
  }
}
