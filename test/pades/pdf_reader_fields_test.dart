// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:opencie/services/ltv/pades/pdf_reader.dart';

/// Builds a minimal classic-xref-table PDF from a list of object body
/// strings (e.g. `'<< /Type /Catalog ... >>'`). `objBodies[i]` becomes
/// object number `i + 1`. Byte offsets for the xref table are computed
/// from the accumulated buffer length as each object is appended, never
/// hand-counted.
Uint8List _buildPdf(List<String> objBodies, {int rootObjNum = 1}) {
  final out = BytesBuilder();
  out.add(utf8.encode('%PDF-1.7\n'));

  final offsets = <int>[];
  for (var i = 0; i < objBodies.length; i++) {
    offsets.add(out.length);
    out.add(utf8.encode('${i + 1} 0 obj\n${objBodies[i]}\nendobj\n'));
  }

  final xrefOffset = out.length;
  final size = objBodies.length + 1;
  final xref = StringBuffer()
    ..write('xref\n')
    ..write('0 $size\n')
    ..write('0000000000 65535 f \n');
  for (final offset in offsets) {
    xref.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.add(utf8.encode(xref.toString()));
  out.add(
    utf8.encode(
      'trailer\n<< /Size $size /Root $rootObjNum 0 R >>\n'
      'startxref\n$xrefOffset\n%%EOF',
    ),
  );
  return out.toBytes();
}

void main() {
  group('PdfReader.findSignatureFields', () {
    test('single /FT /Sig field on a MediaBox-only page', () {
      final bytes = _buildPdf([
        '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
        '<< /Type /Pages /Kids [4 0 R] /Count 1 /MediaBox [0 0 612 792] >>',
        '<< /Fields [5 0 R] >>',
        '<< /Type /Page /Parent 2 0 R /Annots [5 0 R] >>',
        '<< /FT /Sig /T (Signature1) /Rect [100 100 300 200] /P 4 0 R >>',
      ]);

      final fields = PdfReader(bytes).findSignatureFields();

      expect(fields, hasLength(1));
      final f = fields.single;
      expect(f.name, 'Signature1');
      expect(f.pageIndex, 0);
      expect(f.x, closeTo(100 / 612, 1e-9));
      expect(f.y, closeTo(100 / 792, 1e-9));
      expect(f.width, closeTo(200 / 612, 1e-9));
      expect(f.height, closeTo(100 / 792, 1e-9));
    });

    test('/FT inherited from a parent field node is recognised', () {
      final bytes = _buildPdf([
        '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
        '<< /Type /Pages /Kids [4 0 R] /Count 1 /MediaBox [0 0 612 792] >>',
        '<< /Fields [5 0 R] >>',
        '<< /Type /Page /Parent 2 0 R /Annots [6 0 R] >>',
        '<< /FT /Sig /T (sig) /Kids [6 0 R] >>',
        '<< /T (1) /Rect [100 100 300 200] /P 4 0 R >>',
      ]);

      final fields = PdfReader(bytes).findSignatureFields();

      expect(fields, hasLength(1));
    });

    test('fully qualified name is dot-joined ancestor-first through the '
        'parent chain', () {
      final bytes = _buildPdf([
        '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
        '<< /Type /Pages /Kids [4 0 R] /Count 1 /MediaBox [0 0 612 792] >>',
        '<< /Fields [5 0 R] >>',
        '<< /Type /Page /Parent 2 0 R /Annots [6 0 R] >>',
        '<< /FT /Sig /T (sig) /Kids [6 0 R] >>',
        '<< /T (1) /Rect [100 100 300 200] /P 4 0 R >>',
      ]);

      final fields = PdfReader(bytes).findSignatureFields();

      // Convention observed in _collectSigFieldWidgets: qualifiedName is
      // '<parent /T>.<child /T>' — ancestor-first, dot-separated.
      expect(fields.single.name, 'sig.1');
    });

    test('/CropBox inherited from /Pages is used over /MediaBox', () {
      final bytes = _buildPdf([
        '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
        '<< /Type /Pages /Kids [4 0 R] /Count 1 '
            '/MediaBox [0 0 612 792] /CropBox [50 50 550 750] >>',
        '<< /Fields [5 0 R] >>',
        '<< /Type /Page /Parent 2 0 R /Annots [5 0 R] >>',
        '<< /FT /Sig /T (Signature1) /Rect [100 100 300 200] /P 4 0 R >>',
      ]);

      final fields = PdfReader(bytes).findSignatureFields();

      expect(fields, hasLength(1));
      final f = fields.single;
      expect(f.x, closeTo(50 / 500, 1e-9));
      expect(f.y, closeTo(50 / 700, 1e-9));
      expect(f.width, closeTo(200 / 500, 1e-9));
      expect(f.height, closeTo(100 / 700, 1e-9));
    });

    test('/CropBox with a non-zero origin has the origin subtracted', () {
      final bytes = _buildPdf([
        '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
        '<< /Type /Pages /Kids [4 0 R] /Count 1 /MediaBox [0 0 612 792] >>',
        '<< /Fields [5 0 R] >>',
        '<< /Type /Page /Parent 2 0 R /CropBox [20 20 632 812] '
            '/Annots [5 0 R] >>',
        '<< /FT /Sig /T (Signature1) /Rect [100 100 300 200] /P 4 0 R >>',
      ]);

      final fields = PdfReader(bytes).findSignatureFields();

      expect(fields, hasLength(1));
      final f = fields.single;
      expect(f.x, closeTo(80 / 612, 1e-9));
      expect(f.y, closeTo(80 / 792, 1e-9));
      expect(f.width, closeTo(200 / 612, 1e-9));
      expect(f.height, closeTo(100 / 792, 1e-9));
    });

    test('reversed /Rect normalises to the same result as an ordered one', () {
      final bytes = _buildPdf([
        '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
        '<< /Type /Pages /Kids [4 0 R] /Count 1 /MediaBox [0 0 612 792] >>',
        '<< /Fields [5 0 R] >>',
        '<< /Type /Page /Parent 2 0 R /Annots [5 0 R] >>',
        '<< /FT /Sig /T (Signature1) /Rect [300 200 100 100] /P 4 0 R >>',
      ]);

      final fields = PdfReader(bytes).findSignatureFields();

      expect(fields, hasLength(1));
      final f = fields.single;
      expect(f.x, closeTo(100 / 612, 1e-9));
      expect(f.y, closeTo(100 / 792, 1e-9));
      expect(f.width, closeTo(200 / 612, 1e-9));
      expect(f.height, closeTo(100 / 792, 1e-9));
    });

    test('degenerate (zero-width) /Rect is skipped', () {
      final bytes = _buildPdf([
        '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
        '<< /Type /Pages /Kids [4 0 R] /Count 1 /MediaBox [0 0 612 792] >>',
        '<< /Fields [5 0 R] >>',
        '<< /Type /Page /Parent 2 0 R /Annots [5 0 R] >>',
        '<< /FT /Sig /T (Signature1) /Rect [100 100 100 200] /P 4 0 R >>',
      ]);

      expect(PdfReader(bytes).findSignatureFields(), isEmpty);
    });

    test('non-signature field (/FT /Tx) is skipped', () {
      final bytes = _buildPdf([
        '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
        '<< /Type /Pages /Kids [4 0 R] /Count 1 /MediaBox [0 0 612 792] >>',
        '<< /Fields [5 0 R] >>',
        '<< /Type /Page /Parent 2 0 R /Annots [5 0 R] >>',
        '<< /FT /Tx /T (Text1) /Rect [100 100 300 200] /P 4 0 R >>',
      ]);

      expect(PdfReader(bytes).findSignatureFields(), isEmpty);
    });

    test('PDF with no /AcroForm returns an empty list', () {
      final bytes = _buildPdf(['<< /Type /Catalog >>']);

      expect(PdfReader(bytes).findSignatureFields(), isEmpty);
    });

    test('garbage bytes never throw and return an empty list', () {
      final bytes = Uint8List.fromList('not a pdf'.codeUnits);

      expect(() => PdfReader(bytes).findSignatureFields(), returnsNormally);
      expect(PdfReader(bytes).findSignatureFields(), isEmpty);
    });

    test('a field on the second page reports pageIndex 1', () {
      final bytes = _buildPdf([
        '<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>',
        '<< /Type /Pages /Kids [4 0 R 5 0 R] /Count 2 '
            '/MediaBox [0 0 612 792] >>',
        '<< /Fields [6 0 R] >>',
        '<< /Type /Page /Parent 2 0 R >>',
        '<< /Type /Page /Parent 2 0 R /Annots [6 0 R] >>',
        '<< /FT /Sig /T (Signature1) /Rect [100 100 300 200] /P 5 0 R >>',
      ]);

      final fields = PdfReader(bytes).findSignatureFields();

      expect(fields, hasLength(1));
      expect(fields.single.pageIndex, 1);
    });
  });
}
