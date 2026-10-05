// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';

import 'package:convert/convert.dart';

import '../tsp/tsp_client.dart';
import 'pdf_models.dart';
import 'pdf_reader.dart';
import 'pdf_writer.dart';

/// Upgrades a signed PDF (PAdES-B-B, B-T, or B-LT) to PAdES-B-LTA by appending
/// a Document Time-Stamp (DocTimeStamp) signature via incremental update.
///
/// Per ISO 32000-2 §12.8.5 and ETSI EN 319 142-1 §5.4.3, the DocTimeStamp:
/// - Is a signature dictionary with /Type /DocTimeStamp (not /Sig)
/// - Contains an RFC 3161 TimeStampToken in /Contents
/// - Has /ByteRange covering the entire file except the /Contents placeholder
/// - Is added via a second incremental update (after DSS if present)
///
/// The implementation uses a two-pass approach:
/// 1. Lay out the DocTimeStamp dict with placeholder /Contents and /ByteRange
/// 2. Finalize to get candidate bytes
/// 3. Compute actual byte offsets and hash the signed ranges
/// 4. Request timestamp from TSA
/// 5. Patch the candidate bytes with the real timestamp
///
/// Limitations:
/// - Supports classic xref tables only (not PDF 1.5+ xref streams)
/// - Single signature per PDF (uses the first /Type /Sig object found)
/// - contentsReserveBytes must be large enough for the TST (default 16384 = 8 KB)
///
/// Can be applied repeatedly: each call appends one more DocTimeStamp, which
/// is how the full baseline sequence (B-T stamp, DSS, B-LTA stamp) is built
/// by `LtvSignatureUpgrader`. Earlier revisions are never modified.
class PadesLtaUpgrader {
  PadesLtaUpgrader({
    required this.tspClient,
    required this.tspUrl,
    this.hashAlgorithmOid = '2.16.840.1.101.3.4.2.1', // SHA-256
    this.contentsReserveBytes = 16384,
    this.policyOid,
  }) {
    if (contentsReserveBytes % 2 != 0) {
      throw PadesException(
        'contentsReserveBytes must be even (is hex-encoded)',
      );
    }
    if (contentsReserveBytes < 256) {
      throw PadesException('contentsReserveBytes must be at least 256');
    }
  }

  final TspClient tspClient;
  final Uri tspUrl;
  final String hashAlgorithmOid;

  /// Optional TSA policy OID (RFC 3161 `reqPolicy`). Blank means "none";
  /// a malformed value makes [upgrade] throw [TspException] before any
  /// network access.
  final String? policyOid;

  /// Number of hex characters reserved for /Contents. Must be even, must be
  /// large enough to hold the TST hex-encoded plus padding. Default 16384
  /// (= 8 KB of TST bytes).
  final int contentsReserveBytes;

  /// Adds a DocTimeStamp signature to the PDF via incremental update.
  ///
  /// Input may be a B-B, B-T, or B-LT PDF. The DocTimeStamp signs the entire
  /// document (excluding only its own /Contents bytes).
  ///
  /// Throws [PadesException] on TSA rejection, oversized TST, or PDF parse
  /// failures.
  Future<Uint8List> upgrade(Uint8List pdfBytes) async =>
      (await upgradeWithToken(pdfBytes)).bytes;

  /// Like [upgrade], but also returns the DER TimeStampToken that was
  /// embedded, so callers can inspect the TSA's certificate chain.
  Future<({Uint8List bytes, Uint8List token})> upgradeWithToken(
    Uint8List pdfBytes,
  ) async {
    // Parse PDF
    final reader = PdfReader(pdfBytes);
    final trailer = reader.readTrailer();

    // Initialize writer
    final writer = PdfIncrementalWriter(original: pdfBytes, trailer: trailer);

    // Build placeholder DocTimeStamp dict with reserved /Contents and /ByteRange
    final placeholderDict = _buildPlaceholderDocTimeStampDict();
    final tsRef = writer.addObject(placeholderDict);

    // Wire the DocTimeStamp into Catalog -> AcroForm -> Fields, with a
    // widget annotation on a page (also referenced from that page's
    // /Annots) and /SigFlags set. Per ETSI EN 319 142-1 §5.4 and ISO
    // 32000-2 §12.8.5, a document time-stamp MUST be a proper signature
    // field — a bare indirect /DocTimeStamp object with no field/widget
    // wiring is invisible to conformant validators that walk the form
    // tree (Adobe, EU DSS) even though it hashes and verifies fine on
    // its own (OC-08).
    final catalogRef = trailer.rootRef;
    final catalogBody = _readObjectBody(pdfBytes, trailer, catalogRef);
    if (catalogBody == null) {
      throw PadesException('Could not read catalog object');
    }
    if (RegExp(r'/AcroForm\s*<<').hasMatch(catalogBody)) {
      throw PadesException('inline /AcroForm dictionary is not supported');
    }

    final pageRef = reader.findFirstPageRef();
    if (pageRef == null) {
      throw PadesException(
        'Could not find a page to attach the DocTimeStamp widget to',
      );
    }
    final pageBody = _readObjectBody(pdfBytes, trailer, pageRef);
    if (pageBody == null) {
      throw PadesException('Could not read page object');
    }

    final widgetBody = _buildDocTimeStampWidgetDict(pageRef, tsRef);
    final widgetRef = writer.addObject(widgetBody);

    // AcroForm: reuse the existing indirect dictionary if present,
    // otherwise create one and reference it from the Catalog.
    final acroFormRefMatch = RegExp(
      r'/AcroForm\s+(\d+)\s+(\d+)\s+R',
    ).firstMatch(catalogBody);
    String? newCatalogBody;
    if (acroFormRefMatch != null) {
      final acroFormRef = PdfRef(
        int.parse(acroFormRefMatch.group(1)!),
        int.parse(acroFormRefMatch.group(2)!),
      );
      final acroFormBody = _readObjectBody(pdfBytes, trailer, acroFormRef);
      if (acroFormBody == null) {
        throw PadesException('Could not read AcroForm object');
      }
      writer.updateObject(
        acroFormRef,
        _addFieldToAcroForm(acroFormBody, widgetRef),
      );
    } else {
      final acroFormRef = writer.addObject(
        _addFieldToAcroForm('<< /Fields [] >>', widgetRef),
      );
      final closingIdx = catalogBody.lastIndexOf('>>');
      if (closingIdx < 0) {
        throw PadesException('Catalog dict does not end with >>');
      }
      newCatalogBody =
          '${catalogBody.substring(0, closingIdx)} '
          '/AcroForm ${acroFormRef.objNum} ${acroFormRef.gen} R'
          '${catalogBody.substring(closingIdx)}';
    }
    if (newCatalogBody != null) {
      writer.updateObject(catalogRef, newCatalogBody);
    }

    // Page /Annots: a widget annotation must be discoverable from the
    // page it's displayed on (ISO 32000-2 §12.5.2).
    writer.updateObject(pageRef, _addAnnotToPage(pageBody, widgetRef));

    // Finalize to get candidate bytes
    final candidateBytes = writer.finalize(rootRef: catalogRef);

    // Find the placeholder /ByteRange and /Contents in candidate bytes
    // Only search the appended revision: earlier revisions (the signature,
    // or a previous DocTimeStamp) carry their own /ByteRange and /Contents.
    final byteRangeMatch = _findPlaceholderByteRange(
      candidateBytes,
      from: pdfBytes.length,
    );
    if (byteRangeMatch == null) {
      throw PadesException(
        'Could not find placeholder /ByteRange in candidate bytes',
      );
    }

    final contentsMatch = _findPlaceholderContents(
      candidateBytes,
      from: pdfBytes.length,
    );
    if (contentsMatch == null) {
      throw PadesException(
        'Could not find placeholder /Contents in candidate bytes',
      );
    }

    // Compute actual byte offsets
    // Per ISO 32000-2 §12.8.1: ByteRange is [start1 length1 start2 length2]
    // where the ranges cover everything EXCEPT the /Contents hex bytes.
    // - Range 1: [0, contentsStart] (from start to '<' inclusive)
    // - Range 2: [contentsEnd, totalLen - contentsEnd] (from '>' to EOF)
    final contentsStart = contentsMatch.start; // position of '<'
    final contentsEnd = contentsMatch.end; // position after '>'
    final totalLen = candidateBytes.length;

    final byteRange = [0, contentsStart, contentsEnd, totalLen - contentsEnd];

    // CRITICAL FIX FOR P0-1: Patch /ByteRange FIRST (length-preserving),
    // THEN compute hash of the patched bytes, THEN call TSA.
    // This ensures the hash matches what the validator will compute.
    var workBytes = _patchByteRange(candidateBytes, byteRangeMatch, byteRange);

    // Extract bytes to hash from the patched bytes: [0...contentsStart) + [contentsEnd...EOF)
    final hashInput = BytesBuilder();
    hashInput.add(workBytes.sublist(0, contentsStart));
    hashInput.add(workBytes.sublist(contentsEnd));
    final hashInputBytes = hashInput.toBytes();

    // Request timestamp from TSA
    final tspResp = await tspClient.timestampData(
      tspUrl,
      hashInputBytes,
      hashAlgorithmOid: hashAlgorithmOid,
      requestCert: true,
      policyOid: policyOid,
    );

    if (!tspResp.isSuccess) {
      throw PadesException(
        'TSA rejected timestamp request: ${tspResp.statusStrings.join(', ')}',
      );
    }

    if (tspResp.timeStampToken == null || tspResp.timeStampToken!.isEmpty) {
      throw PadesException('TSA returned empty TimeStampToken');
    }

    // Hex-encode the TST
    final tstHex = hex.encode(tspResp.timeStampToken!).toUpperCase();

    // Check if TST fits in reserved space
    if (tstHex.length > contentsReserveBytes) {
      throw PadesException(
        'TST exceeds reserved /Contents space: '
        '${tstHex.length} > $contentsReserveBytes',
      );
    }

    // Pad TST hex with zeros to fill reserved space
    final paddedTstHex = tstHex.padRight(contentsReserveBytes, '0');

    // Patch /Contents with padded TST hex in the already-patched workBytes
    final patchedBytes = _patchContents(workBytes, contentsMatch, paddedTstHex);

    return (bytes: patchedBytes, token: tspResp.timeStampToken!);
  }

  /// Builds a placeholder DocTimeStamp dictionary with reserved /Contents and /ByteRange.
  /// The /ByteRange is initially [0 0 0 0] and /Contents is all zeros.
  /// The placeholder is designed to be easily replaceable with the same byte length.
  String _buildPlaceholderDocTimeStampDict() {
    final buf = StringBuffer();
    buf.write('<<\n');
    buf.write('/Type /DocTimeStamp\n');
    buf.write('/Filter /Adobe.PPKLite\n');
    buf.write('/SubFilter /ETSI.RFC3161\n');

    // Placeholder /ByteRange with fixed width (10 digits per number)
    // Format: [0 0000000000 0000000000 0000000000]
    // This is 47 bytes total: [0 + space + 10 + space + 10 + space + 10 + ]
    buf.write('/ByteRange [0 0000000000 0000000000 0000000000]\n');

    // Placeholder /Contents with reserved zeros
    buf.write('/Contents <');
    buf.write('0' * contentsReserveBytes);
    buf.write('>\n');

    buf.write('>>\n');

    return buf.toString();
  }

  /// Finds the placeholder /ByteRange [0 0000000000 0000000000 0000000000] in bytes.
  /// Returns {start, end} where start is the position of '[' and end is after ']'.
  ({int start, int end})? _findPlaceholderByteRange(
    Uint8List bytes, {
    int from = 0,
  }) {
    // The placeholder is: /ByteRange [0 0000000000 0000000000 0000000000]
    // We search for the pattern starting with /ByteRange
    const prefix = '/ByteRange [';
    final prefixBytes = prefix.codeUnits;

    for (int i = from; i <= bytes.length - prefixBytes.length; i++) {
      bool match = true;
      for (int j = 0; j < prefixBytes.length; j++) {
        if (bytes[i + j] != prefixBytes[j]) {
          match = false;
          break;
        }
      }

      if (match) {
        // Found /ByteRange [, now find the closing ]
        int end = i + prefixBytes.length;

        // Skip digits and spaces until we find ]
        while (end < bytes.length && bytes[end] != 0x5D) {
          // 0x5D = ']'
          end++;
        }

        if (end < bytes.length && bytes[end] == 0x5D) {
          return (start: i, end: end + 1);
        }
      }
    }

    return null;
  }

  /// Finds the placeholder /Contents <000...000> in bytes.
  /// Returns {start, end} where start is the position of '<' and end is after '>'.
  ({int start, int end})? _findPlaceholderContents(
    Uint8List bytes, {
    int from = 0,
  }) {
    // Look for /Contents < followed by zeros and >
    const prefix = '/Contents <';
    final prefixBytes = prefix.codeUnits;

    for (int i = from; i <= bytes.length - prefixBytes.length; i++) {
      bool match = true;
      for (int j = 0; j < prefixBytes.length; j++) {
        if (bytes[i + j] != prefixBytes[j]) {
          match = false;
          break;
        }
      }

      if (match) {
        // Found /Contents <, now find the closing >
        final contentsStart = i + prefixBytes.length - 1; // position of '<'
        int contentsEnd = contentsStart + 1;

        // Skip hex digits (0-9, A-F, a-f)
        while (contentsEnd < bytes.length) {
          final byte = bytes[contentsEnd];
          if ((byte >= 0x30 && byte <= 0x39) || // 0-9
              (byte >= 0x41 && byte <= 0x46) || // A-F
              (byte >= 0x61 && byte <= 0x66)) {
            // a-f
            contentsEnd++;
          } else {
            break;
          }
        }

        // Expect '>'
        if (contentsEnd < bytes.length && bytes[contentsEnd] == 0x3E) {
          // '>'
          return (start: contentsStart, end: contentsEnd + 1);
        }
      }
    }

    return null;
  }

  /// Patches the /ByteRange placeholder with actual values.
  /// Replaces /ByteRange [0 0000000000 0000000000 0000000000] with /ByteRange [0 aaaaaaaaaa bbbbbbbbbb cccccccccc]
  /// maintaining the same byte length by padding with spaces if needed.
  Uint8List _patchByteRange(
    Uint8List bytes,
    ({int start, int end}) match,
    List<int> byteRange,
  ) {
    // Format the new ByteRange with fixed-width numbers, including the /ByteRange prefix
    final newByteRange =
        '/ByteRange [0 ${byteRange[1].toString().padLeft(10, '0')} '
        '${byteRange[2].toString().padLeft(10, '0')} '
        '${byteRange[3].toString().padLeft(10, '0')}]';

    final placeholderLen = match.end - match.start;

    // Pad with spaces if needed to maintain the same byte length
    final paddedByteRange = newByteRange.padRight(placeholderLen, ' ');
    final paddedBytes = paddedByteRange.codeUnits;

    if (paddedBytes.length != placeholderLen) {
      throw PadesException(
        'ByteRange patch length mismatch: '
        '${paddedBytes.length} != $placeholderLen',
      );
    }

    final result = BytesBuilder();
    result.add(bytes.sublist(0, match.start));
    result.add(paddedBytes);
    result.add(bytes.sublist(match.end));

    return result.toBytes();
  }

  /// Patches the /Contents placeholder with the actual TST hex.
  /// Replaces the zeros between < and > with the padded TST hex.
  Uint8List _patchContents(
    Uint8List bytes,
    ({int start, int end}) match,
    String tstHex,
  ) {
    // match.start points to '<', match.end points after '>'
    // We need to replace everything between < and >

    final tstHexBytes = tstHex.codeUnits;

    // The placeholder should have the same length
    final placeholderLen = match.end - match.start - 2; // -2 for < and >
    if (tstHexBytes.length != placeholderLen) {
      throw PadesException(
        'Contents patch length mismatch: '
        '${tstHexBytes.length} != $placeholderLen',
      );
    }

    final result = BytesBuilder();
    result.add(bytes.sublist(0, match.start + 1)); // include '<'
    result.add(tstHexBytes);
    result.add(bytes.sublist(match.end - 1)); // include '>'

    return result.toBytes();
  }

  /// Builds a signature-field widget annotation for the DocTimeStamp,
  /// per ISO 32000-2 §12.7.4.3 (Widget annotations) / §12.7.3.3
  /// (Signature fields): `/FT /Sig`, `/V` pointing at the DocTimeStamp
  /// signature dictionary, `/P` pointing at the hosting page. Uses a
  /// near-zero (but non-degenerate) /Rect since a document time-stamp
  /// has no visible appearance to render.
  String _buildDocTimeStampWidgetDict(PdfRef pageRef, PdfRef tsRef) {
    return '<< /Type /Annot /Subtype /Widget /FT /Sig '
        '/Rect [0 0 1 1] /F 4 '
        '/P ${pageRef.objNum} ${pageRef.gen} R '
        '/V ${tsRef.objNum} ${tsRef.gen} R '
        '/T (DocTimeStamp_${tsRef.objNum}) >>';
  }

  /// Appends [fieldRef] to the AcroForm's /Fields array (creating it if
  /// absent) and ensures /SigFlags has SignaturesExist(1) | AppendOnly(2)
  /// set (ISO 32000-2 §12.7.2, Table 225) so conformant viewers treat any
  /// further incremental update as append-only rather than
  /// signature-invalidating.
  String _addFieldToAcroForm(String acroFormBody, PdfRef fieldRef) {
    var updated = acroFormBody;

    final fieldsArrayMatch = RegExp(
      r'/Fields\s*\[([^\]]*)\]',
    ).firstMatch(updated);
    if (fieldsArrayMatch != null) {
      final existing = fieldsArrayMatch.group(0)!;
      final newFieldsArray =
          '${existing.substring(0, existing.length - 1)} '
          '${fieldRef.objNum} ${fieldRef.gen} R]';
      updated = updated.replaceRange(
        fieldsArrayMatch.start,
        fieldsArrayMatch.end,
        newFieldsArray,
      );
    } else if (RegExp(r'/Fields\s+\d+\s+\d+\s+R').hasMatch(updated)) {
      throw PadesException(
        'AcroForm /Fields as an indirect array is not supported',
      );
    } else {
      final closingIdx = updated.lastIndexOf('>>');
      if (closingIdx < 0) {
        throw PadesException('AcroForm dict does not end with >>');
      }
      updated =
          '${updated.substring(0, closingIdx)} '
          '/Fields [${fieldRef.objNum} ${fieldRef.gen} R]'
          '${updated.substring(closingIdx)}';
    }

    final sigFlagsMatch = RegExp(r'/SigFlags\s+(\d+)').firstMatch(updated);
    if (sigFlagsMatch != null) {
      final current = int.parse(sigFlagsMatch.group(1)!);
      final merged = current | 3;
      if (merged != current) {
        updated = updated.replaceRange(
          sigFlagsMatch.start,
          sigFlagsMatch.end,
          '/SigFlags $merged',
        );
      }
    } else {
      final closingIdx = updated.lastIndexOf('>>');
      if (closingIdx < 0) {
        throw PadesException('AcroForm dict does not end with >>');
      }
      updated =
          '${updated.substring(0, closingIdx)} /SigFlags 3'
          '${updated.substring(closingIdx)}';
    }

    return updated;
  }

  /// Appends [annotRef] to the page's /Annots array, creating it if
  /// absent (ISO 32000-2 §12.5.2: a widget must be reachable from its
  /// page's /Annots to be discoverable/interactive).
  String _addAnnotToPage(String pageBody, PdfRef annotRef) {
    final annotsArrayMatch = RegExp(
      r'/Annots\s*\[([^\]]*)\]',
    ).firstMatch(pageBody);
    if (annotsArrayMatch != null) {
      final existing = annotsArrayMatch.group(0)!;
      final newAnnotsArray =
          '${existing.substring(0, existing.length - 1)} '
          '${annotRef.objNum} ${annotRef.gen} R]';
      return pageBody.replaceRange(
        annotsArrayMatch.start,
        annotsArrayMatch.end,
        newAnnotsArray,
      );
    }
    if (RegExp(r'/Annots\s+\d+\s+\d+\s+R').hasMatch(pageBody)) {
      throw PadesException(
        'Page /Annots as an indirect array is not supported',
      );
    }
    final closingIdx = pageBody.lastIndexOf('>>');
    if (closingIdx < 0) {
      throw PadesException('Page dict does not end with >>');
    }
    return '${pageBody.substring(0, closingIdx)} '
        '/Annots [${annotRef.objNum} ${annotRef.gen} R]'
        '${pageBody.substring(closingIdx)}';
  }

  /// Reads the raw dict body text of an existing indirect object (between
  /// `N G obj` and `endobj`). Mirrors PadesLtUpgrader's identically-named
  /// helper.
  String? _readObjectBody(
    Uint8List pdfBytes,
    PdfTrailerInfo trailer,
    PdfRef ref,
  ) {
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

    int pos = entry.offset;
    while (pos < pdfBytes.length && pdfBytes[pos] != 0x6F) {
      // 'o'
      pos++;
    }
    if (pos + 3 > pdfBytes.length) return null;
    pos += 3; // skip "obj"

    while (pos < pdfBytes.length && _isWhitespace(pdfBytes[pos])) {
      pos++;
    }

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

  /// Helper: is whitespace
  bool _isWhitespace(int byte) {
    return byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D;
  }
}
