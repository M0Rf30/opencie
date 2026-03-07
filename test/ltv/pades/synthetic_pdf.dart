// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

/// Builds a minimal synthetic signed PDF for testing.
/// Structure:
/// - Catalog (obj 1)
/// - Pages (obj 2)
/// - Page (obj 3)
/// - Signature dict (obj 4)
/// - xref + trailer
Uint8List buildSyntheticSignedPdf({
  Uint8List? cmsContents,
}) {
  cmsContents ??= Uint8List.fromList([0x30, 0x80, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02]);
  // Encode CMS as hex
  final cmsHex = _bytesToHex(cmsContents);

  // Build objects
  final obj1 = '1 0 obj\n<</Type/Catalog/Pages 2 0 R>>\nendobj\n';
  final obj2 = '2 0 obj\n<</Type/Pages/Kids[3 0 R]/Count 1>>\nendobj\n';
  final obj3 = '3 0 obj\n<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>\nendobj\n';
  final obj4 = '4 0 obj\n<</Type/Sig/Filter/Adobe.PPKLite/SubFilter/ETSI.CAdES.detached/Contents<$cmsHex>/ByteRange[0 100 200 50]>>\nendobj\n';

  // Build xref
  final header = '%PDF-1.7\n%\xE2\xE3\xCF\xD3\n';
  final body = obj1 + obj2 + obj3 + obj4;

  // Calculate offsets
  final offset1 = header.length;
  final offset2 = offset1 + obj1.length;
  final offset3 = offset2 + obj2.length;
  final offset4 = offset3 + obj3.length;

  final xrefStart = offset4 + obj4.length;

  final xref = 'xref\n'
      '0 5\n'
      '0000000000 65535 f \n'
      '${offset1.toString().padLeft(10, '0')} 00000 n \n'
      '${offset2.toString().padLeft(10, '0')} 00000 n \n'
      '${offset3.toString().padLeft(10, '0')} 00000 n \n'
      '${offset4.toString().padLeft(10, '0')} 00000 n \n';

  final trailer = 'trailer\n'
      '<</Size 5/Root 1 0 R/ID[<4142434445464748494A4B4C4D4E4F50><4142434445464748494A4B4C4D4E4F50]>>\n'
      'startxref\n'
      '$xrefStart\n'
      '%%EOF\n';

  final pdf = header + body + xref + trailer;
  return Uint8List.fromList(pdf.codeUnits);
}

/// Encode bytes to hex string
String _bytesToHex(Uint8List bytes) {
  final buf = StringBuffer();
  for (final byte in bytes) {
    buf.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}
