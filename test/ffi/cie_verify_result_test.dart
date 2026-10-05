// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/ffi/opencie_pkcs11.dart';

void main() {
  group('cieVerifyFailed', () {
    test('count returned on success is not an error', () {
      expect(cieVerifyFailed(2, 2), isFalse);
    });

    test('a file without signatures is not an error', () {
      expect(cieVerifyFailed(0, 0), isFalse);
    });

    test('CIE_SIGN_ERROR_* (positive on 64-bit) is an error', () {
      expect(cieVerifyFailed(0x84000001, 0), isTrue);
    });

    test('a negative status cast to CK_RV is an error', () {
      expect(cieVerifyFailed(-1, 0), isTrue);
    });

    test('a small error code with no signatures is an error', () {
      expect(cieVerifyFailed(5, 0), isTrue);
    });
  });
}
