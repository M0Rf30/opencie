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
class PadesLtaUpgrader {
  PadesLtaUpgrader({
    required this.tspClient,
    required this.tspUrl,
    this.hashAlgorithmOid = '2.16.840.1.101.3.4.2.1', // SHA-256
    this.contentsReserveBytes = 16384,
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
  Future<Uint8List> upgrade(Uint8List pdfBytes) async {
    // Parse PDF
    final reader = PdfReader(pdfBytes);
    final trailer = reader.readTrailer();

    // Initialize writer
    final writer = PdfIncrementalWriter(original: pdfBytes, trailer: trailer);

    // Build placeholder DocTimeStamp dict with reserved /Contents and /ByteRange
    final placeholderDict = _buildPlaceholderDocTimeStampDict();
    writer.addObject(placeholderDict);

    // Finalize to get candidate bytes
    final candidateBytes = writer.finalize(rootRef: trailer.rootRef);

    // Find the placeholder /ByteRange and /Contents in candidate bytes
    final byteRangeMatch = _findPlaceholderByteRange(candidateBytes);
    if (byteRangeMatch == null) {
      throw PadesException(
        'Could not find placeholder /ByteRange in candidate bytes',
      );
    }

    final contentsMatch = _findPlaceholderContents(candidateBytes);
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

    return patchedBytes;
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
  ({int start, int end})? _findPlaceholderByteRange(Uint8List bytes) {
    // The placeholder is: /ByteRange [0 0000000000 0000000000 0000000000]
    // We search for the pattern starting with /ByteRange
    const prefix = '/ByteRange [';
    final prefixBytes = prefix.codeUnits;

    for (int i = 0; i <= bytes.length - prefixBytes.length; i++) {
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
  ({int start, int end})? _findPlaceholderContents(Uint8List bytes) {
    // Look for /Contents < followed by zeros and >
    const prefix = '/Contents <';
    final prefixBytes = prefix.codeUnits;

    for (int i = 0; i <= bytes.length - prefixBytes.length; i++) {
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
}
