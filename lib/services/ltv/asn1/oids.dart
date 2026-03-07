// SPDX-License-Identifier: GPL-3.0-or-later

/// RFC 3161, RFC 5280, RFC 5652, ETSI EN 319 122/142 OIDs used by LTV.
abstract class Oid {
  // Hash algorithms (RFC 8017, NIST)
  static const sha256 = '2.16.840.1.101.3.4.2.1';
  static const sha384 = '2.16.840.1.101.3.4.2.2';
  static const sha512 = '2.16.840.1.101.3.4.2.3';
  static const sha1 = '1.3.14.3.2.26'; // legacy

  // Signature algorithms
  static const rsaEncryption = '1.2.840.113549.1.1.1';
  static const sha256WithRSA = '1.2.840.113549.1.1.11';
  static const sha384WithRSA = '1.2.840.113549.1.1.12';
  static const sha512WithRSA = '1.2.840.113549.1.1.13';
  static const ecPublicKey = '1.2.840.10045.2.1';
  static const ecdsaWithSha256 = '1.2.840.10045.4.3.2';
  static const ecdsaWithSha384 = '1.2.840.10045.4.3.3';
  static const ecdsaWithSha512 = '1.2.840.10045.4.3.4';

  // PKCS#7 / CMS (RFC 5652)
  static const pkcs7Data = '1.2.840.113549.1.7.1';
  static const pkcs7SignedData = '1.2.840.113549.1.7.2';
  static const contentType = '1.2.840.113549.1.9.3';
  static const messageDigest = '1.2.840.113549.1.9.4';
  static const signingTime = '1.2.840.113549.1.9.5';
  static const countersignature = '1.2.840.113549.1.9.6';

  // RFC 3161 timestamping
  static const timeStampToken = '1.2.840.113549.1.9.16.1.4';
  static const tstInfo = '1.2.840.113549.1.9.16.1.4'; // alias
  static const signatureTimeStampToken =
      '1.2.840.113549.1.9.16.2.14'; // id-aa-signatureTimeStampToken

  // CAdES unsigned attributes (RFC 5126 / ETSI EN 319 122)
  static const certificateValues =
      '1.2.840.113549.1.9.16.2.23'; // id-aa-ets-certValues
  static const revocationValues =
      '1.2.840.113549.1.9.16.2.24'; // id-aa-ets-revocationValues
  static const archiveTimeStampV3 =
      '1.2.840.113549.1.9.16.2.48'; // id-aa-ets-archiveTimestampV3
  static const atsHashIndexV3 = '0.4.0.19122.1.4'; // ETSI ats-hash-index-v3

  // X.509 v3 extensions (RFC 5280)
  static const subjectKeyIdentifier = '2.5.29.14';
  static const authorityKeyIdentifier = '2.5.29.35';
  static const basicConstraints = '2.5.29.19';
  static const crlDistributionPoints = '2.5.29.31';
  static const authorityInfoAccess = '1.3.6.1.5.5.7.1.1';
  static const aiaOcsp = '1.3.6.1.5.5.7.48.1';
  static const aiaCaIssuers = '1.3.6.1.5.5.7.48.2';

  // OCSP (RFC 6960)
  static const ocspBasic = '1.3.6.1.5.5.7.48.1.1';
  static const ocspNonce = '1.3.6.1.5.5.7.48.1.2';

  /// Map sigAlgOid -> hash OID (sha256/sha384/sha512). Returns null for unknown.
  static String? hashForSignatureAlgorithm(String sigAlgOid) {
    switch (sigAlgOid) {
      case sha256WithRSA:
      case ecdsaWithSha256:
        return sha256;
      case sha384WithRSA:
      case ecdsaWithSha384:
        return sha384;
      case sha512WithRSA:
      case ecdsaWithSha512:
        return sha512;
      default:
        return null;
    }
  }
}
