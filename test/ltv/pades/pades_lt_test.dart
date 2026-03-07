// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/services/ltv/asn1/der.dart';
import 'package:opencie/services/ltv/crl/crl_models.dart';
import 'package:opencie/services/ltv/ocsp/ocsp_models.dart';
import 'package:opencie/services/ltv/pades/pdf_models.dart';
import 'package:opencie/services/ltv/pades/pades_lt.dart';
import 'package:opencie/services/ltv/pades/pdf_reader.dart';
import 'synthetic_pdf.dart';

void main() {
  group('PadesLtUpgrader', () {
    test('upgrades PDF with single cert and OCSP', () {
      final pdf = buildSyntheticSignedPdf();
      final upgrader = PadesLtUpgrader();

      // Create validation material
      final cert = Uint8List.fromList([0x30, 0x82, 0x01, 0x00]); // dummy cert
      final ocspResp = OcspResponse(
        status: OcspResponseStatus.successful,
        rawResponse: Uint8List.fromList([0x30, 0x82, 0x02, 0x00]), // dummy OCSP
      );

      final material = PdfValidationMaterial(
        certificates: [cert],
        ocspResponses: [ocspResp],
      );

      final upgraded = upgrader.upgrade(pdf, material);

      // Output should be larger
      expect(upgraded.length, greaterThan(pdf.length));

      // Original bytes should be preserved
      expect(upgraded.sublist(0, pdf.length), pdf);

      // Should be parseable
      final reader = PdfReader(upgraded);
      final trailer = reader.readTrailer();
      expect(trailer.size, greaterThan(5));
    });

    test('upgrades PDF with cert, CRL, and OCSP', () {
      final pdf = buildSyntheticSignedPdf();
      final upgrader = PadesLtUpgrader();

      final cert = Uint8List.fromList([0x30, 0x82, 0x01, 0x00]);
      final crlData = CrlData(
        rawCrl: Uint8List.fromList([0x30, 0x82, 0x01, 0x50]),
        issuerDn: Uint8List.fromList([0x30, 0x10]),
        thisUpdate: DateTime.now(),
      );
      final ocspResp = OcspResponse(
        status: OcspResponseStatus.successful,
        rawResponse: Uint8List.fromList([0x30, 0x82, 0x02, 0x00]),
      );

      final material = PdfValidationMaterial(
        certificates: [cert],
        crls: [crlData],
        ocspResponses: [ocspResp],
      );

      final upgraded = upgrader.upgrade(pdf, material);

      expect(upgraded.length, greaterThan(pdf.length));

      final reader = PdfReader(upgraded);
      final trailer = reader.readTrailer();
      expect(trailer.size, greaterThan(5));
    });

    test('throws on empty validation material', () {
      final pdf = buildSyntheticSignedPdf();
      final upgrader = PadesLtUpgrader();
      final material = PdfValidationMaterial();

      expect(
        () => upgrader.upgrade(pdf, material),
        throwsA(isA<PadesException>()),
      );
    });

    test('throws on PDF without signature', () {
      // Build PDF without signature
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
      final upgrader = PadesLtUpgrader();

      final material = PdfValidationMaterial(
        certificates: [Uint8List.fromList([0x30, 0x82])],
      );

      expect(
        () => upgrader.upgrade(pdf, material),
        throwsA(isA<PadesException>()),
      );
    });

    test('signature contents hash is computed correctly', () {
      final cmsBytes = Uint8List.fromList([0x30, 0x81, 0x82, 0x06, 0x09, 0x2A, 0x86, 0x48]);
      final pdf = buildSyntheticSignedPdf(cmsContents: cmsBytes);
      final upgrader = PadesLtUpgrader();

      final material = PdfValidationMaterial(
        certificates: [Uint8List.fromList([0x30, 0x82])],
      );

      final upgraded = upgrader.upgrade(pdf, material);

      // The upgraded PDF should contain a DSS dict with a VRI key
      // that is the SHA1 hash of the CMS bytes
      final expectedHash = sha1Of(cmsBytes);
      final expectedHashHex = _bytesToHex(expectedHash).toUpperCase();

      final upgradedStr = String.fromCharCodes(upgraded);
      expect(upgradedStr.contains('/$expectedHashHex'), true);
    });

    test('original signature is preserved', () {
      final cmsBytes = Uint8List.fromList([0x30, 0x81, 0x82, 0x06, 0x09, 0x2A, 0x86, 0x48]);
      final pdf = buildSyntheticSignedPdf(cmsContents: cmsBytes);

      // Extract original signature contents
      final reader = PdfReader(pdf);
      final origSig = reader.findSignatureContentsRange();
      expect(origSig, isNotNull);

      final origHex = String.fromCharCodes(
        pdf.sublist(origSig!.contentsStart, origSig.contentsEnd),
      );

      final upgrader = PadesLtUpgrader();
      final material = PdfValidationMaterial(
        certificates: [Uint8List.fromList([0x30, 0x82])],
      );

      final upgraded = upgrader.upgrade(pdf, material);

      // The original bytes should be preserved (signature is in the original part)
      expect(upgraded.sublist(0, pdf.length), pdf);

      // The signature hex should still be at the same location in the original part
      final preservedHex = String.fromCharCodes(
        upgraded.sublist(origSig.contentsStart, origSig.contentsEnd),
      );

      // Hex should be identical
      expect(preservedHex, origHex);
    });

    test('DSS dict is added to catalog', () {
      final pdf = buildSyntheticSignedPdf();
      final upgrader = PadesLtUpgrader();

      final material = PdfValidationMaterial(
        certificates: [Uint8List.fromList([0x30, 0x82])],
      );

      final upgraded = upgrader.upgrade(pdf, material);
      final upgradedStr = String.fromCharCodes(upgraded);

      // Should contain /DSS reference
      expect(upgradedStr.contains('/DSS'), true);

      // Should contain /Type /DSS
      expect(upgradedStr.contains('/Type /DSS'), true);
    });

    test('VRI dict contains timestamp', () {
      final pdf = buildSyntheticSignedPdf();
      final upgrader = PadesLtUpgrader();

      final material = PdfValidationMaterial(
        certificates: [Uint8List.fromList([0x30, 0x82])],
      );

      final upgraded = upgrader.upgrade(pdf, material);
      final upgradedStr = String.fromCharCodes(upgraded);

      // Should contain /TU with timestamp
      expect(upgradedStr.contains('/TU (D:'), true);
    });

    test('multiple certificates are embedded', () {
      final pdf = buildSyntheticSignedPdf();
      final upgrader = PadesLtUpgrader();

      final cert1 = Uint8List.fromList([0x30, 0x82, 0x01, 0x00]);
      final cert2 = Uint8List.fromList([0x30, 0x82, 0x02, 0x00]);
      final cert3 = Uint8List.fromList([0x30, 0x82, 0x03, 0x00]);

      final material = PdfValidationMaterial(
        certificates: [cert1, cert2, cert3],
      );

      final upgraded = upgrader.upgrade(pdf, material);

      // Parse and check size
      final reader = PdfReader(upgraded);
      final trailer = reader.readTrailer();

      // Should have added objects for 3 certs + VRI + DSS = 5 new objects
      expect(trailer.size, greaterThanOrEqualTo(5 + 5));
    });
  });
}

/// Encode bytes to hex string
String _bytesToHex(Uint8List bytes) {
  final buf = StringBuffer();
  for (final byte in bytes) {
    buf.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}
