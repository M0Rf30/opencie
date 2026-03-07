// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:typed_data';
import 'pdf_models.dart';

/// Reference to an indirect PDF object.
class PdfRef {
  PdfRef(this.objNum, this.gen);
  final int objNum;
  final int gen;

  @override
  String toString() => '$objNum $gen R';
}

/// Entry in the xref table.
class PdfXrefEntry {
  PdfXrefEntry({
    required this.objNum,
    required this.offset,
    required this.gen,
    required this.inUse,
  });
  final int objNum;
  final int offset;  // byte offset in file (for in-use entries)
  final int gen;
  final bool inUse;  // true = 'n', false = 'f'
}

/// Parsed trailer info from a PDF.
class PdfTrailerInfo {
  PdfTrailerInfo({
    required this.prevXrefOffset,
    required this.size,
    required this.rootRef,
    this.id,
    required this.xrefEntries,
  });
  final int prevXrefOffset;       // value of `startxref` near the end
  final int size;                 // /Size from trailer
  final PdfRef rootRef;           // /Root
  final Uint8List? id;            // /ID (raw bytes of the array, or null)
  final List<PdfXrefEntry> xrefEntries;  // all entries from the existing xref
}

/// Minimal PDF reader to extract what we need for incremental update.
/// Supports classic xref tables only (not xref streams).
class PdfReader {
  PdfReader(this.bytes);
  final Uint8List bytes;

  /// Parses the trailer and the most recent xref table.
  /// Throws [PadesException] on malformed input.
  PdfTrailerInfo readTrailer() {
    // Find %%EOF and startxref
    final eofPos = _findEof();
    if (eofPos < 0) {
      throw PadesException('PDF does not end with %%EOF');
    }

    // Search backwards for startxref
    final startxrefPos = _findStartxref(eofPos);
    if (startxrefPos < 0) {
      throw PadesException('startxref not found before %%EOF');
    }

    // Extract the xref offset
    final xrefOffsetStr = _extractNumber(startxrefPos);
    final xrefOffset = int.tryParse(xrefOffsetStr);
    if (xrefOffset == null || xrefOffset < 0) {
      throw PadesException('Invalid startxref offset: $xrefOffsetStr');
    }

    // Check if this is an xref stream (PDF 1.5+) or malformed xref
    // A classic xref table starts with the literal ASCII bytes "xref" followed by whitespace.
    // If that keyword is NOT present, it's likely an xref stream or malformed.
    if (!_matchKeyword(xrefOffset, 'xref')) {
      throw PadesException(
        'xref stream not supported (or malformed xref) at offset $xrefOffset',
      );
    }

    // Parse the xref table
    final xrefEntries = _parseXref(xrefOffset);

    // Parse the trailer dict
    final trailerStart = _findTrailerKeyword(xrefOffset);
    if (trailerStart < 0) {
      throw PadesException('trailer keyword not found');
    }

    final trailerDict = _parseTrailerDict(trailerStart);

    return PdfTrailerInfo(
      prevXrefOffset: xrefOffset,
      size: trailerDict['size'] as int,
      rootRef: trailerDict['rootRef'] as PdfRef,
      id: trailerDict['id'] as Uint8List?,
      xrefEntries: xrefEntries,
    );
  }

  /// Locates the signature object (first object whose dict has /Type /Sig and /Contents).
  /// Returns the byte range of /Contents as a record with objNum, contentsStart, contentsEnd.
  /// contentsStart and contentsEnd point at the HEX bytes between `<` and `>` (exclusive of brackets).
  /// Returns null if not found.
  ({int objNum, int contentsStart, int contentsEnd})? findSignatureContentsRange() {
    final trailer = readTrailer();

    for (final entry in trailer.xrefEntries) {
      if (!entry.inUse) continue;
      if (entry.offset < 0 || entry.offset >= bytes.length) continue;

      // Try to parse this object
      final objStart = entry.offset;
      final objBody = _extractObjectBody(objStart);
      if (objBody == null) continue;

      // Check if it has /Type /Sig
      if (!objBody.contains('/Type') || !objBody.contains('/Sig')) continue;

      // Look for /Contents <...>
      final contentsMatch = _findContentsHexRange(objBody, objStart);
      if (contentsMatch != null) {
        return (
          objNum: entry.objNum,
          contentsStart: contentsMatch.start,
          contentsEnd: contentsMatch.end,
        );
      }
    }

    return null;
  }

  /// Find the position of %%EOF
  int _findEof() {
    const eofMarker = '%%EOF';
    final eofBytes = eofMarker.codeUnits;
    // Search backwards from end
    for (int i = bytes.length - 1; i >= bytes.length - 1024 && i >= 0; i--) {
      if (i + eofBytes.length <= bytes.length) {
        bool match = true;
        for (int j = 0; j < eofBytes.length; j++) {
          if (bytes[i + j] != eofBytes[j]) {
            match = false;
            break;
          }
        }
        if (match) {
          return i;
        }
      }
    }
    return -1;
  }

  /// Find startxref keyword before EOF
  int _findStartxref(int eofPos) {
    const keyword = 'startxref';
    final keywordBytes = keyword.codeUnits;
    // Search backwards from EOF
    for (int i = eofPos - 1; i >= 0 && i > eofPos - 1024; i--) {
      if (i + keywordBytes.length <= bytes.length) {
        bool match = true;
        for (int j = 0; j < keywordBytes.length; j++) {
          if (bytes[i + j] != keywordBytes[j]) {
            match = false;
            break;
          }
        }
        if (match) {
          return i;
        }
      }
    }
    return -1;
  }

  /// Extract a number after startxref
  String _extractNumber(int startxrefPos) {
    int pos = startxrefPos + 9; // length of "startxref"
    // Skip whitespace
    while (pos < bytes.length && _isWhitespace(bytes[pos])) {
      pos++;
    }
    // Extract digits
    final numStart = pos;
    while (pos < bytes.length && _isDigit(bytes[pos])) {
      pos++;
    }
    return String.fromCharCodes(bytes.sublist(numStart, pos));
  }

  /// Parse xref table at given offset
  List<PdfXrefEntry> _parseXref(int offset) {
    if (offset < 0 || offset >= bytes.length) {
      throw PadesException('xref offset out of bounds');
    }

    // Expect "xref" keyword
    const xrefKeyword = 'xref';
    final xrefBytes = xrefKeyword.codeUnits;
    for (int i = 0; i < xrefBytes.length; i++) {
      if (offset + i >= bytes.length || bytes[offset + i] != xrefBytes[i]) {
        throw PadesException('xref keyword not found at offset $offset');
      }
    }

    int pos = offset + 4; // skip "xref"
    _skipWhitespace(pos);
    pos = _skipWhitespaceFrom(pos);

    final entries = <PdfXrefEntry>[];

    // Parse subsections
    while (pos < bytes.length) {
      // Check for "trailer" keyword
      if (_matchKeyword(pos, 'trailer')) {
        break;
      }

      // Parse subsection header: "start count"
      final startStr = _extractNumberAt(pos);
      if (startStr.isEmpty) break;
      final start = int.tryParse(startStr) ?? -1;
      if (start < 0) break;

      pos = _skipWhitespaceFrom(pos + startStr.length);

      final countStr = _extractNumberAt(pos);
      if (countStr.isEmpty) break;
      final count = int.tryParse(countStr) ?? -1;
      if (count < 0) break;

      pos = _skipWhitespaceFrom(pos + countStr.length);

      // Parse entries
      for (int i = 0; i < count; i++) {
        if (pos + 20 > bytes.length) {
          throw PadesException('xref entry truncated');
        }

        // Each entry is exactly 20 bytes: "OOOOOOOOOO GGGGG n|f \n"
        final offsetStr = String.fromCharCodes(bytes.sublist(pos, pos + 10));
        final genStr = String.fromCharCodes(bytes.sublist(pos + 11, pos + 16));
        final status = bytes[pos + 17]; // 'n' = 110, 'f' = 102

        final entryOffset = int.tryParse(offsetStr) ?? 0;
        final gen = int.tryParse(genStr) ?? 0;
        final inUse = status == 110; // 'n'

        entries.add(
          PdfXrefEntry(
            objNum: start + i,
            offset: entryOffset,
            gen: gen,
            inUse: inUse,
          ),
        );

        pos += 20;
      }
    }

    return entries;
  }

  /// Find trailer keyword
  int _findTrailerKeyword(int xrefOffset) {
    const keyword = 'trailer';
    final keywordBytes = keyword.codeUnits;
    for (int i = xrefOffset; i < bytes.length - keywordBytes.length; i++) {
      bool match = true;
      for (int j = 0; j < keywordBytes.length; j++) {
        if (bytes[i + j] != keywordBytes[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }

  /// Parse trailer dict and extract /Size, /Root, /ID
  Map<String, dynamic> _parseTrailerDict(int trailerPos) {
    int pos = trailerPos + 7; // skip "trailer"
    pos = _skipWhitespaceFrom(pos);

    // Expect <<
    if (pos + 1 >= bytes.length || bytes[pos] != 0x3C || bytes[pos + 1] != 0x3C) {
      throw PadesException('trailer dict does not start with <<');
    }
    pos += 2;

    int size = 0;
    PdfRef? rootRef;
    Uint8List? id;

    // Parse dict entries
    while (pos < bytes.length) {
      pos = _skipWhitespaceFrom(pos);

      // Check for >>
      if (pos + 1 < bytes.length && bytes[pos] == 0x3E && bytes[pos + 1] == 0x3E) {
        break;
      }

      // Expect /
      if (bytes[pos] != 0x2F) {
        pos++;
        continue;
      }
      pos++;

      // Extract key
      final keyStart = pos;
      while (pos < bytes.length && _isNameChar(bytes[pos])) {
        pos++;
      }
      final key = String.fromCharCodes(bytes.sublist(keyStart, pos));

      pos = _skipWhitespaceFrom(pos);

      if (key == 'Size') {
        final numStr = _extractNumberAt(pos);
        size = int.tryParse(numStr) ?? 0;
        pos += numStr.length;
      } else if (key == 'Root') {
        // Expect "N M R"
        final numStr = _extractNumberAt(pos);
        final objNum = int.tryParse(numStr) ?? 0;
        pos = _skipWhitespaceFrom(pos + numStr.length);

        final genStr = _extractNumberAt(pos);
        final gen = int.tryParse(genStr) ?? 0;
        pos = _skipWhitespaceFrom(pos + genStr.length);

        // Expect R
        if (pos < bytes.length && bytes[pos] == 0x52) { // 'R'
          rootRef = PdfRef(objNum, gen);
          pos++;
        }
      } else if (key == 'ID') {
        // Expect [<...> <...>]
        pos = _skipWhitespaceFrom(pos);
        if (pos < bytes.length && bytes[pos] == 0x5B) { // '['
          final idStart = pos;
          pos++;
          int depth = 1;
          while (pos < bytes.length && depth > 0) {
            if (bytes[pos] == 0x5B) depth++;
            if (bytes[pos] == 0x5D) depth--;
            pos++;
          }
          id = bytes.sublist(idStart, pos);
        }
      } else {
        // Skip unknown entry
        _skipDictValue(pos);
        pos = _skipWhitespaceFrom(pos);
      }
    }

    if (rootRef == null) {
      throw PadesException('trailer /Root not found');
    }

    return {
      'size': size,
      'rootRef': rootRef,
      'id': id,
    };
  }

  /// Extract object body (dict or stream) starting at offset
  String? _extractObjectBody(int offset) {
    if (offset + 10 > bytes.length) return null;

    // Expect "N M obj"
    int pos = offset;
    while (pos < bytes.length && _isDigit(bytes[pos])) {
      pos++;
    }
    pos = _skipWhitespaceFrom(pos);
    while (pos < bytes.length && _isDigit(bytes[pos])) {
      pos++;
    }
    pos = _skipWhitespaceFrom(pos);

    const objKeyword = 'obj';
    if (!_matchKeyword(pos, objKeyword)) return null;
    pos += 3;

    pos = _skipWhitespaceFrom(pos);

    // Extract until "endobj"
    const endKeyword = 'endobj';
    int endPos = pos;
    while (endPos < bytes.length - endKeyword.length) {
      if (_matchKeyword(endPos, endKeyword)) {
        break;
      }
      endPos++;
    }

    if (endPos >= bytes.length - endKeyword.length) return null;

    return String.fromCharCodes(bytes.sublist(pos, endPos)).trim();
  }

  /// Find /Contents <...> in object body and return (startOfHex, endOfHex)
  ({int start, int end})? _findContentsHexRange(String objBody, int objStartOffset) {
    const contentsKey = '/Contents';
    final idx = objBody.indexOf(contentsKey);
    if (idx < 0) return null;

    int pos = idx + contentsKey.length;
    // Skip whitespace
    while (pos < objBody.length && _isWhitespaceChar(objBody[pos])) {
      pos++;
    }

    // Expect <
    if (pos >= objBody.length || objBody[pos] != '<') return null;
    pos++;

    // Find matching >
    while (pos < objBody.length && objBody[pos] != '>') {
      pos++;
    }
    if (pos >= objBody.length) return null;

    // Convert to absolute byte offsets in the original PDF
    // This is approximate; we return the offsets relative to objStartOffset
    // For simplicity, we'll search in the actual bytes
    final contentsStr = '/Contents';
    int searchPos = objStartOffset;
    while (searchPos < bytes.length - contentsStr.length) {
      bool match = true;
      for (int i = 0; i < contentsStr.length; i++) {
        if (bytes[searchPos + i] != contentsStr.codeUnits[i]) {
          match = false;
          break;
        }
      }
      if (match) {
        // Found /Contents in bytes
        int hexPos = searchPos + contentsStr.length;
        // Skip whitespace
        while (hexPos < bytes.length && _isWhitespace(bytes[hexPos])) {
          hexPos++;
        }
        // Expect <
        if (hexPos < bytes.length && bytes[hexPos] == 0x3C) {
          hexPos++;
          final start = hexPos;
          // Find >
          while (hexPos < bytes.length && bytes[hexPos] != 0x3E) {
            hexPos++;
          }
          if (hexPos < bytes.length) {
            return (start: start, end: hexPos);
          }
        }
        break;
      }
      searchPos++;
    }

    return null;
  }

  /// Helper: match keyword at position
  bool _matchKeyword(int pos, String keyword) {
    final bytes = keyword.codeUnits;
    if (pos + bytes.length > this.bytes.length) return false;
    for (int i = 0; i < bytes.length; i++) {
      if (this.bytes[pos + i] != bytes[i]) return false;
    }
    return true;
  }

  /// Helper: skip whitespace from position
  int _skipWhitespaceFrom(int pos) {
    while (pos < bytes.length && _isWhitespace(bytes[pos])) {
      pos++;
    }
    return pos;
  }

  /// Helper: skip whitespace in-place
  void _skipWhitespace(int pos) {
    while (pos < bytes.length && _isWhitespace(bytes[pos])) {
      pos++;
    }
  }

  /// Helper: extract number at position
  String _extractNumberAt(int pos) {
    final start = pos;
    while (pos < bytes.length && _isDigit(bytes[pos])) {
      pos++;
    }
    return String.fromCharCodes(bytes.sublist(start, pos));
  }

  /// Helper: skip dict value (simplified)
  void _skipDictValue(int pos) {
    while (pos < bytes.length) {
      if (bytes[pos] == 0x2F) break; // next key
      if (pos + 1 < bytes.length && bytes[pos] == 0x3E && bytes[pos + 1] == 0x3E) break;
      pos++;
    }
  }

  /// Helper: is whitespace
  bool _isWhitespace(int byte) {
    return byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D;
  }

  /// Helper: is whitespace char
  bool _isWhitespaceChar(String char) {
    return char == ' ' || char == '\t' || char == '\n' || char == '\r';
  }

  /// Helper: is digit
  bool _isDigit(int byte) {
    return byte >= 0x30 && byte <= 0x39;
  }

  /// Helper: is name character
  bool _isNameChar(int byte) {
    return (byte >= 0x21 && byte <= 0x7E) && byte != 0x2F && byte != 0x3C && byte != 0x3E && byte != 0x5B && byte != 0x5D && byte != 0x7B && byte != 0x7D && byte != 0x25;
  }
}
