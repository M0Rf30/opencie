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
  final int offset; // byte offset in file (for in-use entries)
  final int gen;
  final bool inUse; // true = 'n', false = 'f'
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
  final int prevXrefOffset; // value of `startxref` near the end
  final int size; // /Size from trailer
  final PdfRef rootRef; // /Root
  final Uint8List? id; // /ID (raw bytes of the array, or null)
  final List<PdfXrefEntry> xrefEntries; // all entries from the existing xref
}

/// A signature field (`/FT /Sig`) discovered in the document's AcroForm,
/// with its widget rectangle expressed as fractions of the page's crop
/// box — the same 0.0-1.0 convention SignatureOptions.x/y/width/height use.
///
/// This describes an EXISTING field's rectangle only. The native signer
/// always CREATES a brand-new signature field at the chosen rect; it never
/// fills this one. Callers should offer this as "align to this field's
/// position", never as "sign this field".
///
/// /Rotate is ignored: a field on a rotated page will be positioned
/// incorrectly by this reader.
class PdfSignatureFieldInfo {
  PdfSignatureFieldInfo({
    required this.name,
    required this.pageIndex,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  /// Fully qualified field name (this field's /T and its ancestors',
  /// joined with '.').
  final String name;

  /// 0-based page index the field's widget annotation sits on.
  final int pageIndex;

  /// Left edge, as a fraction of the page crop box width (0.0-1.0).
  final double x;

  /// Bottom edge, as a fraction of the page crop box height (0.0-1.0),
  /// measured bottom-up like the PDF coordinate system itself.
  final double y;

  /// Width as a fraction of the page crop box width (0.0-1.0).
  final double width;

  /// Height as a fraction of the page crop box height (0.0-1.0).
  final double height;
}

/// Wraps a PDF /Name token so generic value parsing can tell it apart
/// from a text string (e.g. /FT /Sig vs /T (Signature1)) — both decode
/// to a Dart [String] but PDF treats them as distinct types.
class _PdfName {
  _PdfName(this.value);
  final String value;
}

/// A page's geometry and identity, as collected by walking the page tree.
class _PdfPageInfo {
  _PdfPageInfo({
    required this.index,
    required this.objNum,
    required this.boxX0,
    required this.boxY0,
    required this.boxX1,
    required this.boxY1,
    required this.annotObjNums,
  });
  final int index;
  final int objNum;
  final double boxX0;
  final double boxY0;
  final double boxX1;
  final double boxY1;
  final Set<int> annotObjNums;
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
  ({int objNum, int contentsStart, int contentsEnd})?
  findSignatureContentsRange() {
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

  /// Enumerates the document's AcroForm signature fields (`/FT /Sig`) so
  /// the UI can offer "align the new signature to this field's rectangle".
  ///
  /// This does NOT resolve which field the generated signature will fill —
  /// the native signer always creates a brand-new /Sig field at the chosen
  /// rect (see pdf_signature_generator.cpp); it never fills an existing
  /// one. Only the existing field's rectangle is reused, mapped to
  /// fractions of that page's crop box (falling back to the media box),
  /// the same convention already used for placement.
  ///
  /// /Rotate is ignored, so fields on rotated pages get wrong fractions.
  ///
  /// Never throws: this is a convenience lookup, so anything this minimal
  /// reader cannot parse (xref streams, a missing/malformed AcroForm,
  /// degenerate rects, etc.) simply yields an empty list rather than
  /// breaking signing of an otherwise-valid PDF.
  List<PdfSignatureFieldInfo> findSignatureFields() {
    try {
      final trailer = readTrailer();
      final objOffsets = <int, int>{};
      for (final entry in trailer.xrefEntries) {
        if (entry.inUse) objOffsets[entry.objNum] = entry.offset;
      }

      final root = _resolve(trailer.rootRef, objOffsets);
      if (root is! Map<String, Object?>) return const [];

      final acroForm = _resolve(root['AcroForm'], objOffsets);
      if (acroForm is! Map<String, Object?>) return const [];

      final fieldsArray = _resolve(acroForm['Fields'], objOffsets);
      if (fieldsArray is! List<Object?>) return const [];

      final pages = _collectPages(root['Pages'], objOffsets);
      if (pages.isEmpty) return const [];

      final results = <PdfSignatureFieldInfo>[];
      final visited = <int>{};
      for (final fieldRef in fieldsArray) {
        _collectSigFieldWidgets(
          fieldRef,
          objOffsets,
          pages,
          results,
          '',
          null,
          visited,
          0,
        );
      }
      return results;
    } catch (_) {
      return const [];
    }
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
    if (pos + 1 >= bytes.length ||
        bytes[pos] != 0x3C ||
        bytes[pos + 1] != 0x3C) {
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
      if (pos + 1 < bytes.length &&
          bytes[pos] == 0x3E &&
          bytes[pos + 1] == 0x3E) {
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
        if (pos < bytes.length && bytes[pos] == 0x52) {
          // 'R'
          rootRef = PdfRef(objNum, gen);
          pos++;
        }
      } else if (key == 'ID') {
        // Expect [<...> <...>]
        pos = _skipWhitespaceFrom(pos);
        if (pos < bytes.length && bytes[pos] == 0x5B) {
          // '['
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

    return {'size': size, 'rootRef': rootRef, 'id': id};
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
  ({int start, int end})? _findContentsHexRange(
    String objBody,
    int objStartOffset,
  ) {
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
      if (pos + 1 < bytes.length &&
          bytes[pos] == 0x3E &&
          bytes[pos + 1] == 0x3E) {
        break;
      }
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
    return (byte >= 0x21 && byte <= 0x7E) &&
        byte != 0x2F &&
        byte != 0x3C &&
        byte != 0x3E &&
        byte != 0x5B &&
        byte != 0x5D &&
        byte != 0x7B &&
        byte != 0x7D &&
        byte != 0x25;
  }

  // ─── Generic PDF value parsing, used by findSignatureFields(). ───
  // Deliberately separate from the byte-scanning above (which only ever
  // looks for specific known keywords): this is a small recursive-descent
  // parser for arbitrary PDF dictionaries/arrays/refs, needed to walk the
  // catalog -> AcroForm -> Fields -> Page tree graph.

  /// Follows indirect references until a concrete value is reached.
  Object? _resolve(Object? value, Map<int, int> objOffsets, [int depth = 0]) {
    if (depth > 32) return null;
    if (value is PdfRef) {
      return _resolve(
        _getObject(value.objNum, objOffsets),
        objOffsets,
        depth + 1,
      );
    }
    return value;
  }

  /// Parses the indirect object [objNum] and returns its value, or null
  /// if it isn't present in the xref table or can't be parsed.
  Object? _getObject(int objNum, Map<int, int> objOffsets) {
    final offset = objOffsets[objNum];
    if (offset == null || offset < 0 || offset >= bytes.length) return null;
    final range = _objectBodyRange(offset);
    if (range == null) return null;
    return _parsePdfValue(range.start).value;
  }

  /// Like [_extractObjectBody], but returns the body's byte range instead
  /// of an extracted [String], so the generic parser below can work
  /// directly on [bytes].
  ({int start, int end})? _objectBodyRange(int offset) {
    if (offset + 10 > bytes.length) return null;
    int pos = offset;
    while (pos < bytes.length && _isDigit(bytes[pos])) {
      pos++;
    }
    pos = _skipWhitespaceFrom(pos);
    while (pos < bytes.length && _isDigit(bytes[pos])) {
      pos++;
    }
    pos = _skipWhitespaceFrom(pos);
    if (!_matchKeyword(pos, 'obj')) return null;
    pos += 3;
    pos = _skipWhitespaceFrom(pos);

    const endKeyword = 'endobj';
    int endPos = pos;
    while (endPos < bytes.length - endKeyword.length) {
      if (_matchKeyword(endPos, endKeyword)) break;
      endPos++;
    }
    if (endPos >= bytes.length - endKeyword.length) return null;
    return (start: pos, end: endPos);
  }

  /// Parses one PDF value (dict, array, name, string, number, ref, bool,
  /// null) starting at [pos].
  ({Object? value, int pos}) _parsePdfValue(int pos) {
    pos = _skipWs(pos);
    if (pos >= bytes.length) return (value: null, pos: pos);
    final b = bytes[pos];
    if (b == 0x2F) return _parseName(pos);
    if (b == 0x28) return _parseLiteralString(pos);
    if (b == 0x3C) {
      if (pos + 1 < bytes.length && bytes[pos + 1] == 0x3C) {
        return _parseDict(pos);
      }
      return _parseHexString(pos);
    }
    if (b == 0x5B) return _parseArray(pos);
    if (_isDigit(b) || b == 0x2B || b == 0x2D || b == 0x2E) {
      return _parseNumberOrRef(pos);
    }
    if (_matchKeyword(pos, 'true')) return (value: true, pos: pos + 4);
    if (_matchKeyword(pos, 'false')) return (value: false, pos: pos + 5);
    if (_matchKeyword(pos, 'null')) return (value: null, pos: pos + 4);
    // Unrecognised token (e.g. a stream keyword); skip one byte so callers
    // always make progress instead of looping.
    return (value: null, pos: pos + 1);
  }

  ({Object? value, int pos}) _parseName(int pos) {
    pos++; // skip '/'
    final start = pos;
    while (pos < bytes.length && _isNameChar(bytes[pos])) {
      pos++;
    }
    return (
      value: _PdfName(String.fromCharCodes(bytes.sublist(start, pos))),
      pos: pos,
    );
  }

  ({Object? value, int pos}) _parseLiteralString(int pos) {
    pos++; // skip '('
    final out = <int>[];
    int depth = 1;
    while (pos < bytes.length && depth > 0) {
      final c = bytes[pos];
      if (c == 0x5C && pos + 1 < bytes.length) {
        pos++;
        final e = bytes[pos];
        if (e >= 0x30 && e <= 0x37) {
          int val = 0;
          int n = 0;
          while (n < 3 &&
              pos < bytes.length &&
              bytes[pos] >= 0x30 &&
              bytes[pos] <= 0x37) {
            val = val * 8 + (bytes[pos] - 0x30);
            pos++;
            n++;
          }
          out.add(val & 0xFF);
        } else {
          final unescaped = switch (e) {
            0x6E => 0x0A, // \n
            0x72 => 0x0D, // \r
            0x74 => 0x09, // \t
            0x62 => 0x08, // \b
            0x66 => 0x0C, // \f
            _ => e,
          };
          out.add(unescaped);
          pos++;
        }
        continue;
      }
      if (c == 0x28) {
        depth++;
        out.add(c);
        pos++;
        continue;
      }
      if (c == 0x29) {
        depth--;
        pos++;
        if (depth > 0) out.add(c);
        continue;
      }
      out.add(c);
      pos++;
    }
    return (value: _decodeTextString(Uint8List.fromList(out)), pos: pos);
  }

  ({Object? value, int pos}) _parseHexString(int pos) {
    pos++; // skip '<'
    final digits = <int>[];
    while (pos < bytes.length && bytes[pos] != 0x3E) {
      if (_isHexDigit(bytes[pos])) digits.add(bytes[pos]);
      pos++;
    }
    if (pos < bytes.length) pos++; // skip '>'
    if (digits.length.isOdd) digits.add(0x30);
    final out = Uint8List(digits.length ~/ 2);
    for (int i = 0; i < out.length; i++) {
      out[i] = (_hexVal(digits[i * 2]) << 4) | _hexVal(digits[i * 2 + 1]);
    }
    return (value: _decodeTextString(out), pos: pos);
  }

  /// Decodes a PDF text string: UTF-16BE with a `FE FF` BOM, or Latin-1
  /// otherwise (an approximation of PDFDocEncoding, sufficient for the
  /// ASCII field names this reader cares about).
  String _decodeTextString(Uint8List raw) {
    if (raw.length >= 2 && raw[0] == 0xFE && raw[1] == 0xFF) {
      final units = <int>[];
      for (int i = 2; i + 1 < raw.length; i += 2) {
        units.add((raw[i] << 8) | raw[i + 1]);
      }
      return String.fromCharCodes(units);
    }
    return String.fromCharCodes(raw);
  }

  ({Object? value, int pos}) _parseDict(int pos) {
    pos += 2; // skip '<<'
    final map = <String, Object?>{};
    while (true) {
      pos = _skipWs(pos);
      if (pos >= bytes.length) break;
      if (pos + 1 < bytes.length &&
          bytes[pos] == 0x3E &&
          bytes[pos + 1] == 0x3E) {
        pos += 2;
        break;
      }
      if (bytes[pos] != 0x2F) {
        pos++; // malformed; skip stray byte rather than looping forever
        continue;
      }
      final keyResult = _parseName(pos);
      final key = (keyResult.value as _PdfName).value;
      final valueResult = _parsePdfValue(keyResult.pos);
      map[key] = valueResult.value;
      pos = valueResult.pos;
    }
    return (value: map, pos: pos);
  }

  ({Object? value, int pos}) _parseArray(int pos) {
    pos++; // skip '['
    final list = <Object?>[];
    while (true) {
      pos = _skipWs(pos);
      if (pos >= bytes.length) break;
      if (bytes[pos] == 0x5D) {
        pos++;
        break;
      }
      final result = _parsePdfValue(pos);
      list.add(result.value);
      pos = result.pos > pos ? result.pos : pos + 1;
    }
    return (value: list, pos: pos);
  }

  /// Parses a plain number token (int or double, with optional sign).
  ({num? value, int pos}) _parseNumberToken(int pos) {
    final start = pos;
    if (pos < bytes.length && (bytes[pos] == 0x2B || bytes[pos] == 0x2D)) {
      pos++;
    }
    bool isInt = true;
    while (pos < bytes.length && _isDigit(bytes[pos])) {
      pos++;
    }
    if (pos < bytes.length && bytes[pos] == 0x2E) {
      isInt = false;
      pos++;
      while (pos < bytes.length && _isDigit(bytes[pos])) {
        pos++;
      }
    }
    final str = String.fromCharCodes(bytes.sublist(start, pos));
    final value = isInt ? int.tryParse(str) : double.tryParse(str);
    return (value: value, pos: pos);
  }

  ({int value, int pos})? _tryParseUnsignedInt(int pos) {
    final start = pos;
    while (pos < bytes.length && _isDigit(bytes[pos])) {
      pos++;
    }
    if (pos == start) return null;
    return (
      value: int.parse(String.fromCharCodes(bytes.sublist(start, pos))),
      pos: pos,
    );
  }

  /// Numbers and indirect references ("N M R") share a leading digit, so
  /// try the 3-token ref shape first and fall back to a plain number.
  ({Object? value, int pos}) _parseNumberOrRef(int pos) {
    final first = _tryParseUnsignedInt(pos);
    if (first != null) {
      final afterFirst = _skipWs(first.pos);
      final second = _tryParseUnsignedInt(afterFirst);
      if (second != null) {
        final afterSecond = _skipWs(second.pos);
        if (afterSecond < bytes.length &&
            bytes[afterSecond] == 0x52 &&
            (afterSecond + 1 >= bytes.length ||
                !_isNameChar(bytes[afterSecond + 1]))) {
          return (
            value: PdfRef(first.value, second.value),
            pos: afterSecond + 1,
          );
        }
      }
    }
    final numTok = _parseNumberToken(pos);
    return (value: numTok.value, pos: numTok.pos);
  }

  /// Skips whitespace and `%` comments (PDF allows both between tokens).
  int _skipWs(int pos) {
    while (pos < bytes.length) {
      final b = bytes[pos];
      if (_isWhitespace(b)) {
        pos++;
      } else if (b == 0x25) {
        while (pos < bytes.length && bytes[pos] != 0x0A && bytes[pos] != 0x0D) {
          pos++;
        }
      } else {
        break;
      }
    }
    return pos;
  }

  bool _isHexDigit(int b) =>
      (b >= 0x30 && b <= 0x39) ||
      (b >= 0x41 && b <= 0x46) ||
      (b >= 0x61 && b <= 0x66);

  int _hexVal(int b) {
    if (b <= 0x39) return b - 0x30;
    if (b <= 0x46) return b - 0x41 + 10;
    return b - 0x61 + 10;
  }

  /// Resolves [value] to a list of numbers (e.g. /Rect, /CropBox,
  /// /MediaBox), or null if it isn't a well-formed numeric array.
  List<double>? _resolveNumberArray(Object? value, Map<int, int> objOffsets) {
    final resolved = _resolve(value, objOffsets);
    if (resolved is! List<Object?>) return null;
    final out = <double>[];
    for (final e in resolved) {
      final n = _resolve(e, objOffsets);
      if (n is! num) return null;
      out.add(n.toDouble());
    }
    return out;
  }

  /// Walks /Root -> /Pages, inheriting /CropBox and /MediaBox down the
  /// tree, and returns one [_PdfPageInfo] per leaf page in document order.
  List<_PdfPageInfo> _collectPages(
    Object? pagesRoot,
    Map<int, int> objOffsets,
  ) {
    final pages = <_PdfPageInfo>[];
    final visited = <int>{};

    void walk(
      Object? nodeRefOrValue,
      List<double>? inheritedCrop,
      List<double>? inheritedMedia,
      int depth,
    ) {
      if (depth > 64) return;
      int? objNum;
      Object? node = nodeRefOrValue;
      if (node is PdfRef) {
        objNum = node.objNum;
        if (!visited.add(objNum)) return;
        node = _resolve(node, objOffsets);
      }
      if (node is! Map<String, Object?>) return;

      final ownCrop =
          _resolveNumberArray(node['CropBox'], objOffsets) ?? inheritedCrop;
      final ownMedia =
          _resolveNumberArray(node['MediaBox'], objOffsets) ?? inheritedMedia;

      final kids = _resolve(node['Kids'], objOffsets);
      if (kids is List<Object?> && kids.isNotEmpty) {
        for (final kid in kids) {
          walk(kid, ownCrop, ownMedia, depth + 1);
        }
        return;
      }

      final box = ownCrop ?? ownMedia;
      if (box == null || box.length != 4) return;
      final x0 = box[0] < box[2] ? box[0] : box[2];
      final x1 = box[0] < box[2] ? box[2] : box[0];
      final y0 = box[1] < box[3] ? box[1] : box[3];
      final y1 = box[1] < box[3] ? box[3] : box[1];
      if (x1 <= x0 || y1 <= y0) return;

      final annotObjNums = <int>{};
      final annots = _resolve(node['Annots'], objOffsets);
      if (annots is List<Object?>) {
        for (final a in annots) {
          if (a is PdfRef) annotObjNums.add(a.objNum);
        }
      }

      pages.add(
        _PdfPageInfo(
          index: pages.length,
          objNum: objNum ?? -1,
          boxX0: x0,
          boxY0: y0,
          boxX1: x1,
          boxY1: y1,
          annotObjNums: annotObjNums,
        ),
      );
    }

    walk(pagesRoot, null, null, 0);
    return pages;
  }

  /// Walks one AcroForm field subtree, top-down, so /FT and the qualified
  /// /T name are inherited without needing to chase /Parent references.
  /// Recurses into /Kids for both non-terminal fields (sub-fields) and the
  /// multi-widget case (widget annotations with no /FT or /T of their own).
  void _collectSigFieldWidgets(
    Object? nodeRefOrValue,
    Map<int, int> objOffsets,
    List<_PdfPageInfo> pages,
    List<PdfSignatureFieldInfo> results,
    String namePrefix,
    String? inheritedFt,
    Set<int> visited,
    int depth,
  ) {
    if (depth > 64) return;
    int? objNum;
    Object? node = nodeRefOrValue;
    if (node is PdfRef) {
      objNum = node.objNum;
      if (!visited.add(objNum)) return;
      node = _resolve(node, objOffsets);
    }
    if (node is! Map<String, Object?>) return;

    final ownT = _resolve(node['T'], objOffsets);
    final qualifiedName = ownT is String
        ? (namePrefix.isEmpty ? ownT : '$namePrefix.$ownT')
        : namePrefix;

    final ownFtValue = _resolve(node['FT'], objOffsets);
    final effectiveFt = ownFtValue is _PdfName ? ownFtValue.value : inheritedFt;

    final rect = _resolveNumberArray(node['Rect'], objOffsets);
    if (rect != null && rect.length == 4 && effectiveFt == 'Sig') {
      final page = _pageForWidget(node['P'], objNum, pages);
      if (page != null) {
        final info = _rectToFieldInfo(qualifiedName, page, rect);
        if (info != null) results.add(info);
      }
    }

    final kids = _resolve(node['Kids'], objOffsets);
    if (kids is List<Object?>) {
      for (final kid in kids) {
        _collectSigFieldWidgets(
          kid,
          objOffsets,
          pages,
          results,
          qualifiedName,
          effectiveFt,
          visited,
          depth + 1,
        );
      }
    }
  }

  /// Finds the page a widget sits on: prefer its /P entry (recommended by
  /// the spec and present on virtually every real-world form); fall back
  /// to searching each page's /Annots for the widget's own object number.
  _PdfPageInfo? _pageForWidget(
    Object? pValue,
    int? widgetObjNum,
    List<_PdfPageInfo> pages,
  ) {
    if (pValue is PdfRef) {
      for (final page in pages) {
        if (page.objNum == pValue.objNum) return page;
      }
    }
    if (widgetObjNum != null) {
      for (final page in pages) {
        if (page.annotObjNums.contains(widgetObjNum)) return page;
      }
    }
    return null;
  }

  /// Converts a normalised /Rect plus the page box it sits in into
  /// fractions, or null for a degenerate (zero/negative area) rect.
  PdfSignatureFieldInfo? _rectToFieldInfo(
    String name,
    _PdfPageInfo page,
    List<double> rect,
  ) {
    final rx0 = rect[0] < rect[2] ? rect[0] : rect[2];
    final rx1 = rect[0] < rect[2] ? rect[2] : rect[0];
    final ry0 = rect[1] < rect[3] ? rect[1] : rect[3];
    final ry1 = rect[1] < rect[3] ? rect[3] : rect[1];

    final boxWidth = page.boxX1 - page.boxX0;
    final boxHeight = page.boxY1 - page.boxY0;
    final width = rx1 - rx0;
    final height = ry1 - ry0;
    if (width <= 0 || height <= 0 || boxWidth <= 0 || boxHeight <= 0) {
      return null;
    }

    return PdfSignatureFieldInfo(
      name: name,
      pageIndex: page.index,
      x: (rx0 - page.boxX0) / boxWidth,
      y: (ry0 - page.boxY0) / boxHeight,
      width: width / boxWidth,
      height: height / boxHeight,
    );
  }
}
