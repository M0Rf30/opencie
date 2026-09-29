// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/models/signature_options.dart';
import 'package:opencie/services/sign/output_path_resolver.dart';
import 'package:path/path.dart' as p;

void main() {
  group('resolveSignedOutputPath (OC-27)', () {
    test('PAdES: keeps original name, adds _signed suffix, same dir', () async {
      final inputPath = p.join('home', 'user', 'docs', 'contract.pdf');
      final result = await resolveSignedOutputPath(
        inputPath,
        SignatureFormat.pades,
      );

      expect(p.dirname(result), equals(p.join('home', 'user', 'docs')));
      expect(p.basename(result), equals('contract_signed.pdf'));
      // Regression guard: must be built with the platform separator via
      // package:path, never a hardcoded '/'.
      expect(
        result,
        equals(p.join('home', 'user', 'docs', 'contract_signed.pdf')),
      );
    });

    test('CAdES: appends format extension, same dir', () async {
      final inputPath = p.join('home', 'user', 'docs', 'contract.pdf');
      final result = await resolveSignedOutputPath(
        inputPath,
        SignatureFormat.cades,
      );

      expect(p.basename(result), equals('contract.pdf.p7m'));
      expect(p.dirname(result), equals(p.join('home', 'user', 'docs')));
    });

    test('strips existing .p7m before re-signing as CAdES', () async {
      final inputPath = p.join('a', 'b', 'contract.pdf.p7m');
      final result = await resolveSignedOutputPath(
        inputPath,
        SignatureFormat.cades,
      );

      expect(p.basename(result), equals('contract.pdf.p7m'));
    });
  });
}
