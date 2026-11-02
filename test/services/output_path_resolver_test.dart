// SPDX-FileCopyrightText: 2026 Gianluca Boiano
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

    test('a destination folder replaces the input folder (#43)', () async {
      final result = await resolveSignedOutputPath(
        p.join('run', 'doc', 'abc', 'contract.pdf'),
        SignatureFormat.pades,
        destinationFolder: p.join('home', 'user', 'Documents'),
      );

      expect(
        result,
        equals(p.join('home', 'user', 'Documents', 'contract_signed.pdf')),
      );
    }, testOn: '!android');

    test('strips .p7s before re-signing as CAdES', () {
      expect(
        signedFileName(p.join('a', 'contract.pdf.p7s'), SignatureFormat.cades),
        equals('contract.pdf.p7m'),
      );
    });
  });

  group('isDocumentPortalPath (#43)', () {
    test('matches files exported through the portal mounts', () {
      expect(
        isDocumentPortalPath(
          '/run/user/1000/doc/by-app/io.github.m0rf30.opencie/1a2b/x.pdf',
          runtimeDir: '/run/user/1000',
        ),
        isTrue,
      );
      expect(
        isDocumentPortalPath('/run/user/1000/doc/1a2b/x.pdf', runtimeDir: ''),
        isTrue,
      );
      expect(
        isDocumentPortalPath('/run/flatpak/doc/1a2b/x.pdf', runtimeDir: ''),
        isTrue,
      );
    });

    test('honours a non-standard XDG_RUNTIME_DIR', () {
      expect(
        isDocumentPortalPath('/tmp/rt/doc/1a2b/x.pdf', runtimeDir: '/tmp/rt'),
        isTrue,
      );
    });

    test('rejects regular paths and look-alike folders', () {
      for (final path in [
        '/var/home/user/Documents/x.pdf',
        '/home/user/doc/x.pdf',
        '/run/user/1000/documents/x.pdf',
        '/run/user/1000/doc',
      ]) {
        expect(
          isDocumentPortalPath(path, runtimeDir: '/run/user/1000'),
          isFalse,
          reason: path,
        );
      }
    });
  });
}
