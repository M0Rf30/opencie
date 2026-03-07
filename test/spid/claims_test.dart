// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/services/oidc/spid/claims.dart';

void main() {
  group('SpidUserAttributes.fromUserinfo', () {
    test('parses SPID userinfo correctly', () {
      final userinfo = {
        'sub': 'SPID-1234567890',
        'https://attributes.spid.gov.it/name': 'Mario',
        'https://attributes.spid.gov.it/familyName': 'Rossi',
        'https://attributes.spid.gov.it/fiscalNumber':
            'TINIT-RSSMRA80A01H501U',
        'https://attributes.spid.gov.it/dateOfBirth': '1980-01-01',
        'https://attributes.spid.gov.it/email': 'mario.rossi@example.it',
      };

      final attrs = SpidUserAttributes.fromUserinfo(
        userinfo,
        profile: SpidProfile.spid,
      );

      expect(attrs.name, 'Mario');
      expect(attrs.familyName, 'Rossi');
      expect(attrs.fiscalNumber, 'TINIT-RSSMRA80A01H501U');
      expect(attrs.dateOfBirth, '1980-01-01');
      expect(attrs.email, 'mario.rossi@example.it');
    });

    test('parses CIE userinfo correctly', () {
      final userinfo = {
        'sub': 'CIE-9876543210',
        'given_name': 'Mario',
        'family_name': 'Rossi',
        'birthdate': '1980-01-01',
        'email': 'mario.rossi@example.it',
        'https://attributes.eid.gov.it/fiscal_number':
            'TINIT-RSSMRA80A01H501U',
      };

      final attrs = SpidUserAttributes.fromUserinfo(
        userinfo,
        profile: SpidProfile.cie,
      );

      expect(attrs.name, 'Mario');
      expect(attrs.familyName, 'Rossi');
      expect(attrs.dateOfBirth, '1980-01-01');
      expect(attrs.email, 'mario.rossi@example.it');
      expect(attrs.fiscalNumber, 'TINIT-RSSMRA80A01H501U');
    });

    test('handles missing optional fields in SPID', () {
      final userinfo = {
        'sub': 'SPID-1234567890',
        'https://attributes.spid.gov.it/name': 'Mario',
      };

      final attrs = SpidUserAttributes.fromUserinfo(
        userinfo,
        profile: SpidProfile.spid,
      );

      expect(attrs.name, 'Mario');
      expect(attrs.familyName, isNull);
      expect(attrs.email, isNull);
    });

    test('handles missing optional fields in CIE', () {
      final userinfo = {
        'sub': 'CIE-9876543210',
        'given_name': 'Mario',
      };

      final attrs = SpidUserAttributes.fromUserinfo(
        userinfo,
        profile: SpidProfile.cie,
      );

      expect(attrs.name, 'Mario');
      expect(attrs.familyName, isNull);
      expect(attrs.email, isNull);
    });

    test('toJson serializes correctly', () {
      final attrs = SpidUserAttributes(
        name: 'Mario',
        familyName: 'Rossi',
        email: 'mario@example.it',
      );

      final json = attrs.toJson();
      expect(json['name'], 'Mario');
      expect(json['family_name'], 'Rossi');
      expect(json['email'], 'mario@example.it');
      expect(json.containsKey('fiscal_number'), false);
    });
  });
}
