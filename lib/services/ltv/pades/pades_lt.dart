// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import '../asn1/der.dart';
import 'pdf_models.dart';
import 'pdf_reader.dart';
import 'pdf_writer.dart';

/// Upgrades a signed PDF (PAdES-B-B) to PAdES-B-LT by appending a DSS
/// dictionary via incremental update. The original signature is NOT modified.
///
/// Limitations:
/// - Supports classic xref tables only (not PDF 1.5+ xref streams)
/// - Single signature per PDF (uses the first /Type /Sig object found)
/// - Does not chain multiple DSS dictionaries; replaces existing DSS if present
class PadesLtUpgrader {
  PadesLtUpgrader();

  /// Upgrades a signed PDF (PAdES-B-B) to PAdES-B-LT by appending a DSS
  /// dictionary via incremental update. The original signature is NOT modified.
  ///
  /// Throws [PadesException] on parse failure or unsupported PDF features.
  Uint8List upgrade(Uint8List pdfBytes, PdfValidationMaterial material) {
    if (material.isEmpty) {
      throw PadesException('Validation material is empty');
    }

    // Parse PDF
    final reader = PdfReader(pdfBytes);
    final trailer = reader.readTrailer();

    // Find signature
    final sig = reader.findSignatureContentsRange();
    if (sig == null) {
      throw PadesException('No signature found in PDF');
    }

    // Extract CMS contents hex and compute SHA1
    final cmsHexStart = sig.contentsStart;
    final cmsHexEnd = sig.contentsEnd;
    final cmsHexBytes = pdfBytes.sublist(cmsHexStart, cmsHexEnd);
    final cmsHexStr = String.fromCharCodes(cmsHexBytes);

    // Decode hex to get raw CMS bytes
    final cmsBytes = _decodeHex(cmsHexStr);

    // Compute SHA1 of CMS bytes
    final cmsSha1 = sha1Of(cmsBytes);
    final cmsSha1Hex = _bytesToHex(cmsSha1).toUpperCase();

    // Read catalog object
    final catalogRef = trailer.rootRef;
    final catalogBody = _readObjectBody(pdfBytes, trailer, catalogRef);
    if (catalogBody == null) {
      throw PadesException('Could not read catalog object');
    }

    // Initialize writer
    final writer = PdfIncrementalWriter(original: pdfBytes, trailer: trailer);

    // Add validation material as stream objects
    // Per ETSI EN 319 142-1 §B.1, cert/CRL/OCSP streams should NOT have /Type /ObjStm
    // (which is reserved for PDF compressed object streams). Use plain streams instead.
    final certRefs = <PdfRef>[];
    for (final cert in material.certificates) {
      final ref = writer.addStreamObject({}, cert);
      certRefs.add(ref);
    }

    final crlRefs = <PdfRef>[];
    for (final crl in material.crls) {
      final ref = writer.addStreamObject({}, crl.rawCrl);
      crlRefs.add(ref);
    }

    final ocspRefs = <PdfRef>[];
    for (final ocsp in material.ocspResponses) {
      if (ocsp.rawResponse != null) {
        final ref = writer.addStreamObject({}, ocsp.rawResponse!);
        ocspRefs.add(ref);
      }
    }

    // Build VRI dict
    final vriDict = _buildVriDict(certRefs, crlRefs, ocspRefs);
    final vriRef = writer.addObject(vriDict);

    // Build DSS dict
    final dssDict = _buildDssDict(
      certRefs,
      crlRefs,
      ocspRefs,
      vriRef,
      cmsSha1Hex,
    );
    final dssRef = writer.addObject(dssDict);

    // Update catalog with DSS reference
    final newCatalogBody = _updateCatalogWithDss(catalogBody, dssRef);
    writer.updateObject(catalogRef, newCatalogBody);

    // Finalize and return
    return writer.finalize(rootRef: catalogRef);
  }

  /// Build VRI dict string
  String _buildVriDict(
    List<PdfRef> certRefs,
    List<PdfRef> crlRefs,
    List<PdfRef> ocspRefs,
  ) {
    final buf = StringBuffer();
    buf.write('<<');
    buf.write(' /Type /VRI');

    if (certRefs.isNotEmpty) {
      buf.write(' /Cert [');
      for (final ref in certRefs) {
        buf.write('${ref.objNum} ${ref.gen} R ');
      }
      buf.write(']');
    }

    if (crlRefs.isNotEmpty) {
      buf.write(' /CRL [');
      for (final ref in crlRefs) {
        buf.write('${ref.objNum} ${ref.gen} R ');
      }
      buf.write(']');
    }

    if (ocspRefs.isNotEmpty) {
      buf.write(' /OCSP [');
      for (final ref in ocspRefs) {
        buf.write('${ref.objNum} ${ref.gen} R ');
      }
      buf.write(']');
    }

    // Add timestamp
    final now = DateTime.now().toUtc();
    final timestamp = _formatPdfDate(now);
    buf.write(' /TU ($timestamp)');

    buf.write(' >>');
    return buf.toString();
  }

  /// Build DSS dict string
  String _buildDssDict(
    List<PdfRef> certRefs,
    List<PdfRef> crlRefs,
    List<PdfRef> ocspRefs,
    PdfRef vriRef,
    String cmsSha1Hex,
  ) {
    final buf = StringBuffer();
    buf.write('<<');
    buf.write(' /Type /DSS');

    if (certRefs.isNotEmpty) {
      buf.write(' /Certs [');
      for (final ref in certRefs) {
        buf.write('${ref.objNum} ${ref.gen} R ');
      }
      buf.write(']');
    }

    if (crlRefs.isNotEmpty) {
      buf.write(' /CRLs [');
      for (final ref in crlRefs) {
        buf.write('${ref.objNum} ${ref.gen} R ');
      }
      buf.write(']');
    }

    if (ocspRefs.isNotEmpty) {
      buf.write(' /OCSPs [');
      for (final ref in ocspRefs) {
        buf.write('${ref.objNum} ${ref.gen} R ');
      }
      buf.write(']');
    }

    // VRI dict with hash key
    buf.write(' /VRI << /$cmsSha1Hex ${vriRef.objNum} ${vriRef.gen} R >> ');

    buf.write(' >>');
    return buf.toString();
  }

  /// Update catalog body to include /DSS reference
  String _updateCatalogWithDss(String catalogBody, PdfRef dssRef) {
    // Remove existing /DSS if present
    var updated = catalogBody;
    final dssPattern = RegExp(r'/DSS\s+\d+\s+\d+\s+R');
    updated = updated.replaceAll(dssPattern, '');

    // Insert /DSS before closing >>
    final closingIdx = updated.lastIndexOf('>>');
    if (closingIdx < 0) {
      throw PadesException('Catalog dict does not end with >>');
    }

    final dssRef_ = ' /DSS ${dssRef.objNum} ${dssRef.gen} R';
    updated =
        updated.substring(0, closingIdx) +
        dssRef_ +
        updated.substring(closingIdx);

    return updated;
  }

  /// Read object body from PDF given a reference
  String? _readObjectBody(
    Uint8List pdfBytes,
    PdfTrailerInfo trailer,
    PdfRef ref,
  ) {
    // Find the xref entry for this object
    PdfXrefEntry? entry;
    for (final e in trailer.xrefEntries) {
      if (e.objNum == ref.objNum && e.inUse) {
        entry = e;
        break;
      }
    }

    if (entry == null || entry.offset < 0 || entry.offset >= pdfBytes.length) {
      return null;
    }

    // Extract object body
    int pos = entry.offset;

    // Skip "N M obj"
    while (pos < pdfBytes.length && pdfBytes[pos] != 0x6F) {
      // 'o'
      pos++;
    }
    if (pos + 3 > pdfBytes.length) return null;
    pos += 3; // skip "obj"

    // Skip whitespace
    while (pos < pdfBytes.length && _isWhitespace(pdfBytes[pos])) {
      pos++;
    }

    // Find "endobj"
    const endKeyword = 'endobj';
    int endPos = pos;
    while (endPos < pdfBytes.length - endKeyword.length) {
      bool match = true;
      for (int i = 0; i < endKeyword.length; i++) {
        if (pdfBytes[endPos + i] != endKeyword.codeUnits[i]) {
          match = false;
          break;
        }
      }
      if (match) break;
      endPos++;
    }

    if (endPos >= pdfBytes.length - endKeyword.length) return null;

    return String.fromCharCodes(pdfBytes.sublist(pos, endPos)).trim();
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

  /// Encode bytes to hex string
  String _bytesToHex(Uint8List bytes) {
    final buf = StringBuffer();
    for (final byte in bytes) {
      buf.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }

  /// Format DateTime as PDF date string: D:YYYYMMDDHHmmSSZ
  String _formatPdfDate(DateTime dt) {
    return 'D:${dt.year.toString().padLeft(4, '0')}'
        '${dt.month.toString().padLeft(2, '0')}'
        '${dt.day.toString().padLeft(2, '0')}'
        '${dt.hour.toString().padLeft(2, '0')}'
        '${dt.minute.toString().padLeft(2, '0')}'
        '${dt.second.toString().padLeft(2, '0')}Z';
  }

  /// Helper: is whitespace
  bool _isWhitespace(int byte) {
    return byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D;
  }
}
