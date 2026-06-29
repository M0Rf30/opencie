// SPDX-License-Identifier: GPL-3.0-or-later

/// SPID profile type.
enum SpidProfile { spid, cie }

/// SPID claim URI constants.
abstract class SpidClaim {
  static const fiscalNumber = 'https://attributes.spid.gov.it/fiscalNumber';
  static const name = 'https://attributes.spid.gov.it/name';
  static const familyName = 'https://attributes.spid.gov.it/familyName';
  static const dateOfBirth = 'https://attributes.spid.gov.it/dateOfBirth';
  static const placeOfBirth = 'https://attributes.spid.gov.it/placeOfBirth';
  static const gender = 'https://attributes.spid.gov.it/gender';
  static const email = 'https://attributes.spid.gov.it/email';
  static const address = 'https://attributes.spid.gov.it/address';
  static const digitalAddress = 'https://attributes.spid.gov.it/digitalAddress';
}

/// CIE claim URI constants.
abstract class CieClaim {
  static const fiscalNumber = 'https://attributes.eid.gov.it/fiscal_number';
  static const placeOfBirth = 'https://attributes.eid.gov.it/place_of_birth';
  static const address = 'https://attributes.eid.gov.it/address';
  static const digitalAddress = 'https://attributes.eid.gov.it/digital_address';
}

/// Normalized SPID/CIE user attributes.
class SpidUserAttributes {
  SpidUserAttributes({
    this.fiscalNumber,
    this.name,
    this.familyName,
    this.dateOfBirth,
    this.placeOfBirth,
    this.gender,
    this.email,
    this.address,
    this.digitalAddress,
  });

  final String? fiscalNumber;
  final String? name;
  final String? familyName;
  final String? dateOfBirth;
  final String? placeOfBirth;
  final String? gender;
  final String? email;
  final String? address;
  final String? digitalAddress;

  /// Parses userinfo claims into normalized attributes.
  ///
  /// For SPID profile, uses URI-style claim keys.
  /// For CIE profile, uses standard OIDC keys with fallback to URI-style.
  factory SpidUserAttributes.fromUserinfo(
    Map<String, Object?> claims, {
    required SpidProfile profile,
  }) {
    if (profile == SpidProfile.spid) {
      return SpidUserAttributes(
        fiscalNumber: claims[SpidClaim.fiscalNumber] as String?,
        name: claims[SpidClaim.name] as String?,
        familyName: claims[SpidClaim.familyName] as String?,
        dateOfBirth: claims[SpidClaim.dateOfBirth] as String?,
        placeOfBirth: claims[SpidClaim.placeOfBirth] as String?,
        gender: claims[SpidClaim.gender] as String?,
        email: claims[SpidClaim.email] as String?,
        address: claims[SpidClaim.address] as String?,
        digitalAddress: claims[SpidClaim.digitalAddress] as String?,
      );
    } else {
      // CIE: standard OIDC keys with fallback to URI-style
      return SpidUserAttributes(
        fiscalNumber: claims[CieClaim.fiscalNumber] as String?,
        name: claims['given_name'] as String?,
        familyName: claims['family_name'] as String?,
        dateOfBirth: claims['birthdate'] as String?,
        placeOfBirth: claims[CieClaim.placeOfBirth] as String?,
        gender: claims['gender'] as String?,
        email: claims['email'] as String?,
        address: claims[CieClaim.address] as String?,
        digitalAddress: claims[CieClaim.digitalAddress] as String?,
      );
    }
  }

  Map<String, dynamic> toJson() => {
    if (fiscalNumber != null) 'fiscal_number': fiscalNumber,
    if (name != null) 'name': name,
    if (familyName != null) 'family_name': familyName,
    if (dateOfBirth != null) 'date_of_birth': dateOfBirth,
    if (placeOfBirth != null) 'place_of_birth': placeOfBirth,
    if (gender != null) 'gender': gender,
    if (email != null) 'email': email,
    if (address != null) 'address': address,
    if (digitalAddress != null) 'digital_address': digitalAddress,
  };
}
