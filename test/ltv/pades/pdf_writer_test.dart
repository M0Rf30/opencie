// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/services/ltv/pades/pdf_models.dart';
import 'package:opencie/services/ltv/pades/pdf_reader.dart';
import 'package:opencie/services/ltv/pades/pdf_writer.dart';
import 'synthetic_pdf.dart';

void main() {
  group('PdfIncrementalWriter', () {
    test('throws when finalizing with no objects', () {
      final pdf = buildSyntheticSignedPdf();
      final reader = PdfReader(pdf);
      final trailer = reader.readTrailer();

      final writer = PdfIncrementalWriter(original: pdf, trailer: trailer);

      expect(
        () => writer.finalize(rootRef: trailer.rootRef),
        throwsA(isA<PadesException>()),
      );
    });

    test('adds single object and produces valid incremental update', () {
      final pdf = buildSyntheticSignedPdf();
      final reader = PdfReader(pdf);
      final trailer = reader.readTrailer();

      final writer = PdfIncrementalWriter(original: pdf, trailer: trailer);
      writer.addObject('<</Type/Test>>');

      final output = writer.finalize(rootRef: trailer.rootRef);

      // Output should be larger than original
      expect(output.length, greaterThan(pdf.length));

      // Output should start with original bytes
      expect(output.sublist(0, pdf.length), pdf);

      // Output should end with %%EOF
      final outputStr = String.fromCharCodes(output);
      expect(outputStr.endsWith('%%EOF\n'), true);

      // Should be parseable
      final newReader = PdfReader(output);
      final newTrailer = newReader.readTrailer();
      expect(newTrailer.size, greaterThan(trailer.size));
    });

    test('updates existing object', () {
      final pdf = buildSyntheticSignedPdf();
      final reader = PdfReader(pdf);
      final trailer = reader.readTrailer();

      final writer = PdfIncrementalWriter(original: pdf, trailer: trailer);
      final catalogRef = trailer.rootRef;
      writer.updateObject(
        catalogRef,
        '<</Type/Catalog/Pages 2 0 R/DSS 5 0 R>>',
      );

      final output = writer.finalize(rootRef: catalogRef);

      // Parse output
      final newReader = PdfReader(output);
      final newTrailer = newReader.readTrailer();

      // /Prev should point to old xref
      expect(newTrailer.prevXrefOffset, greaterThan(0));
      // The new xref offset should be different (larger)
      expect(newTrailer.prevXrefOffset, lessThan(newReader.bytes.length));
    });

    test('adds stream object', () {
      final pdf = buildSyntheticSignedPdf();
      final reader = PdfReader(pdf);
      final trailer = reader.readTrailer();

      final writer = PdfIncrementalWriter(original: pdf, trailer: trailer);
      final streamData = Uint8List.fromList([0x01, 0x02, 0x03, 0x04]);
      writer.addStreamObject({'/Type': '/ObjStm'}, streamData);

      final output = writer.finalize(rootRef: trailer.rootRef);

      // Output should contain "stream" keyword
      final outputStr = String.fromCharCodes(output);
      expect(outputStr.contains('stream'), true);
      expect(outputStr.contains('endstream'), true);

      // Parse and verify
      final newReader = PdfReader(output);
      final newTrailer = newReader.readTrailer();
      expect(newTrailer.size, greaterThan(trailer.size));
    });

    test('round-trip: append and re-parse', () {
      final pdf = buildSyntheticSignedPdf();
      final reader = PdfReader(pdf);
      final trailer = reader.readTrailer();

      final writer = PdfIncrementalWriter(original: pdf, trailer: trailer);
      writer.addObject('<</Type/Test/Value 42>>');

      final output = writer.finalize(rootRef: trailer.rootRef);

      // Re-parse
      final newReader = PdfReader(output);
      final newTrailer = newReader.readTrailer();

      // /Prev should point to old xref (preserved)
      expect(newTrailer.prevXrefOffset, greaterThan(0));

      // /Size should be incremented
      expect(newTrailer.size, trailer.size + 1);

      // /Root should be unchanged
      expect(newTrailer.rootRef.objNum, trailer.rootRef.objNum);
    });

    test('multiple objects in single update', () {
      final pdf = buildSyntheticSignedPdf();
      final reader = PdfReader(pdf);
      final trailer = reader.readTrailer();

      final writer = PdfIncrementalWriter(original: pdf, trailer: trailer);
      writer.addObject('<</Type/Test1>>');
      writer.addObject('<</Type/Test2>>');
      writer.addStreamObject({
        '/Type': '/ObjStm',
      }, Uint8List.fromList([0xAA, 0xBB]));

      final output = writer.finalize(rootRef: trailer.rootRef);

      // Parse and verify
      final newReader = PdfReader(output);
      final newTrailer = newReader.readTrailer();

      expect(newTrailer.size, trailer.size + 3);
    });
  });
}
