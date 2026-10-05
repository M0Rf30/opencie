// SPDX-FileCopyrightText: 2026 Gianluca Boiano
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

      expect(() => reader.readTrailer(), throwsA(isA<PadesException>()));
    });

    test('returns null for PDF without signature', () {
      // Build PDF without signature object
      final header = '%PDF-1.7\n%\xE2\xE3\xCF\xD3\n';
      final obj1 = '1 0 obj\n<</Type/Catalog/Pages 2 0 R>>\nendobj\n';
      final obj2 = '2 0 obj\n<</Type/Pages/Kids[3 0 R]/Count 1>>\nendobj\n';
      final obj3 =
          '3 0 obj\n<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>\nendobj\n';

      final offset1 = header.length;
      final offset2 = offset1 + obj1.length;
      final offset3 = offset2 + obj2.length;
      final xrefStart = offset3 + obj3.length;

      final xref =
          'xref\n'
          '0 4\n'
          '0000000000 65535 f \n'
          '${offset1.toString().padLeft(10, '0')} 00000 n \n'
          '${offset2.toString().padLeft(10, '0')} 00000 n \n'
          '${offset3.toString().padLeft(10, '0')} 00000 n \n';

      final trailer =
          'trailer\n'
          '<</Size 4/Root 1 0 R/ID[<414243><414243>]>>\n'
          'startxref\n'
          '$xrefStart\n'
          '%%EOF\n';

      final pdf = Uint8List.fromList(
        (header + obj1 + obj2 + obj3 + xref + trailer).codeUnits,
      );
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

    // OC-07: any PDF that has already been through one incremental
    // update (i.e. any signed PDF being LTV-upgraded a second time) has
    // a /Prev-chained trailer. The newest revision's own xref section
    // typically only lists the objects it added/changed, so objects
    // introduced in the first revision (here: the signature object 4)
    // must still be resolvable by following /Prev into the older
    // revision — losing them would misdetect the signature or catalog.
    test('follows /Prev chain across a two-revision PDF (OC-07)', () {
      final rev1 = buildSyntheticSignedPdf();
      final rev1PrevOffset = PdfReader(rev1).readTrailer().prevXrefOffset;

      // Second incremental update: adds object 5, whose own xref
      // subsection only lists object 5 (as a real incremental writer
      // would), chaining back to revision 1 via /Prev.
      final obj5 = '5 0 obj\n<</Type/Test/Marker(rev2)>>\nendobj\n';
      final offset5 = rev1.length;
      final xref2Start = offset5 + obj5.length;
      final xref2 =
          'xref\n5 1\n${offset5.toString().padLeft(10, '0')} 00000 n \n';
      final trailer2 =
          'trailer\n'
          '<</Size 6/Root 1 0 R/Prev $rev1PrevOffset>>\n'
          'startxref\n'
          '$xref2Start\n'
          '%%EOF\n';

      final rev2Tail = (obj5 + xref2 + trailer2).codeUnits;
      final pdf = Uint8List.fromList([...rev1, ...rev2Tail]);

      final reader = PdfReader(pdf);
      final trailer = reader.readTrailer();

      // Newest revision's own values win.
      expect(trailer.size, 6);
      expect(trailer.rootRef.objNum, 1);

      // Merged entries include the new object AND every object only
      // ever declared in the first revision.
      final byObjNum = {for (final e in trailer.xrefEntries) e.objNum: e};
      expect(byObjNum[5]?.inUse, true);
      expect(byObjNum[5]?.offset, offset5);
      for (int i = 1; i <= 4; i++) {
        expect(byObjNum[i]?.inUse, true, reason: 'object $i from revision 1');
      }

      // The signature object only exists in revision 1's xref section;
      // finding it proves the chain was actually followed, not just the
      // newest revision's local table.
      final sig = reader.findSignatureContentsRange();
      expect(sig, isNotNull);
      expect(sig!.objNum, 4);
    });

    test('detects a /Prev cycle instead of looping forever', () {
      final pdf = buildSyntheticSignedPdf();
      final trailer = PdfReader(pdf).readTrailer();
      final xrefOffset = trailer.prevXrefOffset;

      // Rewrite the trailer to point /Prev at itself.
      final asString = String.fromCharCodes(pdf);
      final cyclic = asString.replaceFirst(
        '<</Size 5/Root 1 0 R/ID[<4142434445464748494A4B4C4D4E4F50><4142434445464748494A4B4C4D4E4F50]>>',
        '<</Size 5/Root 1 0 R/Prev $xrefOffset>>',
      );
      final reader = PdfReader(Uint8List.fromList(cyclic.codeUnits));

      expect(() => reader.readTrailer(), throwsA(isA<PadesException>()));
    });

    test('parses a minimal cross-reference stream (PDF 1.5+, OC-07)', () {
      // Build a PDF whose xref is a stream object (ISO 32000-2 §7.5.8)
      // instead of a classic table. Uses no /Filter so the row bytes are
      // exercised directly without needing FlateDecode in the fixture.
      final header = '%PDF-1.5\n%\xE2\xE3\xCF\xD3\n';
      final obj1 = '1 0 obj\n<</Type/Catalog/Pages 2 0 R>>\nendobj\n';
      final obj2 = '2 0 obj\n<</Type/Pages/Kids[3 0 R]/Count 1>>\nendobj\n';
      final obj3 =
          '3 0 obj\n<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>\nendobj\n';

      final offset1 = header.length;
      final offset2 = offset1 + obj1.length;
      final offset3 = offset2 + obj2.length;
      final offset4 = offset3 + obj3.length; // the xref stream object itself

      // W = [1, 4, 1]: 1-byte type, 4-byte big-endian offset, 1-byte gen.
      Uint8List row(int type, int field2, int field3) => Uint8List.fromList([
        type,
        (field2 >> 24) & 0xFF,
        (field2 >> 16) & 0xFF,
        (field2 >> 8) & 0xFF,
        field2 & 0xFF,
        field3,
      ]);
      final rows = BytesBuilder();
      rows.add(row(0, 0, 0)); // obj 0: free
      rows.add(row(1, offset1, 0)); // obj 1: Catalog
      rows.add(row(1, offset2, 0)); // obj 2: Pages
      rows.add(row(1, offset3, 0)); // obj 3: Page
      rows.add(row(1, offset4, 0)); // obj 4: the xref stream itself
      final rowBytes = rows.toBytes();

      final xrefStreamHead =
          '4 0 obj\n<</Type/XRef/Size 5/W[1 4 1]/Root 1 0 R>>stream\n'
              .codeUnits;
      final xrefStreamTail = '\nendstream\nendobj\n'.codeUnits;

      final pdf = Uint8List.fromList([
        ...header.codeUnits,
        ...obj1.codeUnits,
        ...obj2.codeUnits,
        ...obj3.codeUnits,
        ...xrefStreamHead,
        ...rowBytes,
        ...xrefStreamTail,
        ...'startxref\n$offset4\n%%EOF\n'.codeUnits,
      ]);

      final reader = PdfReader(pdf);
      final trailer = reader.readTrailer();

      expect(trailer.size, 5);
      expect(trailer.rootRef.objNum, 1);
      final byObjNum = {for (final e in trailer.xrefEntries) e.objNum: e};
      expect(byObjNum[1]?.offset, offset1);
      expect(byObjNum[2]?.offset, offset2);
      expect(byObjNum[3]?.offset, offset3);
      expect(byObjNum[0]?.inUse, false);
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
