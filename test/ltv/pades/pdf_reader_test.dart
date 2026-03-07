// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/services/ltv/pades/pdf_models.dart';
import 'package:opencie/services/ltv/pades/pdf_reader.dart';
import 'synthetic_pdf.dart';

void main() {
  group('PdfReader', () {
    test('parses synthetic PDF trailer info correctly', () {
      final pdf = buildSyntheticSignedPdf();
      final reader = PdfReader(pdf);
      final trailer = reader.readTrailer();

      expect(trailer.size, 5);
      expect(trailer.rootRef.objNum, 1);
      expect(trailer.rootRef.gen, 0);
      expect(trailer.id, isNotNull);
      expect(trailer.xrefEntries.length, 5);
    });

    test('finds signature contents range', () {
      final pdf = buildSyntheticSignedPdf();
      final reader = PdfReader(pdf);
      final sig = reader.findSignatureContentsRange();

      expect(sig, isNotNull);
      expect(sig!.objNum, 4);
      expect(sig.contentsStart, greaterThan(0));
      expect(sig.contentsEnd, greaterThan(sig.contentsStart));
    });

    test('signature contents bytes match input hex', () {
      final cmsBytes = Uint8List.fromList([0x30, 0x81, 0x82, 0x06, 0x09]);
      final pdf = buildSyntheticSignedPdf(cmsContents: cmsBytes);
      final reader = PdfReader(pdf);
      final sig = reader.findSignatureContentsRange();

      expect(sig, isNotNull);

      // Extract hex from PDF
      final hexBytes = pdf.sublist(sig!.contentsStart, sig.contentsEnd);
      final hexStr = String.fromCharCodes(hexBytes);

      // Decode and compare
      final decoded = _decodeHex(hexStr);
      expect(decoded, cmsBytes);
    });

    test('throws on truncated PDF', () {
      final pdf = buildSyntheticSignedPdf();
      final truncated = pdf.sublist(0, pdf.length ~/ 2);
      final reader = PdfReader(truncated);

      expect(
        () => reader.readTrailer(),
        throwsA(isA<PadesException>()),
      );
    });

    test('returns null for PDF without signature', () {
      // Build PDF without signature object
      final header = '%PDF-1.7\n%\xE2\xE3\xCF\xD3\n';
      final obj1 = '1 0 obj\n<</Type/Catalog/Pages 2 0 R>>\nendobj\n';
      final obj2 = '2 0 obj\n<</Type/Pages/Kids[3 0 R]/Count 1>>\nendobj\n';
      final obj3 = '3 0 obj\n<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>\nendobj\n';

      final offset1 = header.length;
      final offset2 = offset1 + obj1.length;
      final offset3 = offset2 + obj2.length;
      final xrefStart = offset3 + obj3.length;

      final xref = 'xref\n'
          '0 4\n'
          '0000000000 65535 f \n'
          '${offset1.toString().padLeft(10, '0')} 00000 n \n'
          '${offset2.toString().padLeft(10, '0')} 00000 n \n'
          '${offset3.toString().padLeft(10, '0')} 00000 n \n';

      final trailer = 'trailer\n'
          '<</Size 4/Root 1 0 R/ID[<414243><414243>]>>\n'
          'startxref\n'
          '$xrefStart\n'
          '%%EOF\n';

      final pdf = Uint8List.fromList((header + obj1 + obj2 + obj3 + xref + trailer).codeUnits);
      final reader = PdfReader(pdf);

      expect(reader.findSignatureContentsRange(), isNull);
    });

    test('xref entries are parsed correctly', () {
      final pdf = buildSyntheticSignedPdf();
      final reader = PdfReader(pdf);
      final trailer = reader.readTrailer();

      // Check that we have entries for objects 0-4
      expect(trailer.xrefEntries.where((e) => e.inUse).length, 4);

      // Object 0 should be free
      final obj0 = trailer.xrefEntries.firstWhere((e) => e.objNum == 0);
      expect(obj0.inUse, false);

      // Objects 1-4 should be in use
      for (int i = 1; i <= 4; i++) {
        final entry = trailer.xrefEntries.firstWhere((e) => e.objNum == i);
        expect(entry.inUse, true);
        expect(entry.offset, greaterThan(0));
      }
    });

    test('throws on xref stream (PDF 1.5+)', () {
      // Build a PDF with an xref stream instead of classic xref table.
      // The startxref points to an indirect object with /Type /XRef.
      final header = '%PDF-1.5\n%\xE2\xE3\xCF\xD3\n';
      final obj1 = '1 0 obj\n<</Type/Catalog/Pages 2 0 R>>\nendobj\n';
      final obj2 = '2 0 obj\n<</Type/Pages/Kids[3 0 R]/Count 1>>\nendobj\n';
      final obj3 = '3 0 obj\n<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>\nendobj\n';

      final offset1 = header.length;
      final offset2 = offset1 + obj1.length;
      final offset3 = offset2 + obj2.length;
      final xrefStreamStart = offset3 + obj3.length;

      // Xref stream object (minimal, just enough to trigger the detection)
      final xrefStreamObj = '5 0 obj\n<</Type/XRef/Size 4/W[1 2 1]>>stream\n'
          '\x00\x00\x00\x00\x00\x00\x01\x00\x00\x01\x00\x00\x02\x00\x00\x03\x00\x00'
          '\nendstream\nendobj\n';

      final xrefStreamObjStart = xrefStreamStart;

      final trailer = 'trailer\n'
          '<</Size 4/Root 1 0 R/XRefStm 5 0 R/ID[<414243><414243>]>>\n'
          'startxref\n'
          '$xrefStreamObjStart\n'
          '%%EOF\n';

      final pdf = Uint8List.fromList(
        (header + obj1 + obj2 + obj3 + xrefStreamObj + trailer).codeUnits,
      );
      final reader = PdfReader(pdf);

      expect(
        () => reader.readTrailer(),
        throwsA(
          isA<PadesException>().having(
            (e) => e.message,
            'message',
            contains('xref stream not supported'),
          ),
        ),
      );
    });
  });
}

/// Decode hex string to bytes
Uint8List _decodeHex(String hex) {
  final bytes = <int>[];
  for (int i = 0; i < hex.length; i += 2) {
    if (i + 1 < hex.length) {
      final byte = int.parse(hex.substring(i, i + 2), radix: 16);
      bytes.add(byte);
    }
  }
  return Uint8List.fromList(bytes);
}
