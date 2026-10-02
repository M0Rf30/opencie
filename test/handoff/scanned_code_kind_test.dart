// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/services/handoff/scanned_code_kind.dart';

void main() {
  test('JSON with leading whitespace is an OpenCIE code', () {
    expect(classifyScannedCode('  \n{"v":1}'), ScannedCodeKind.openCie);
  });

  test('CIE website login URL', () {
    expect(
      classifyScannedCode(
        'https://idserver.servizicie.interno.gov.it/idp/login/livello2QR'
        '?opText=x&authId=1',
      ),
      ScannedCodeKind.cieWebLogin,
    );
  });

  test('other values', () {
    expect(classifyScannedCode('https://example.com/'), ScannedCodeKind.other);
    expect(
      classifyScannedCode('https://evilservizicie.interno.gov.it/'),
      ScannedCodeKind.other,
    );
    expect(classifyScannedCode('hello'), ScannedCodeKind.other);
    expect(classifyScannedCode(''), ScannedCodeKind.other);
  });
}
