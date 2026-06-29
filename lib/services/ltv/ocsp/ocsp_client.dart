// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pointycastle/asn1.dart';

import '../asn1/der.dart';
import '../asn1/oids.dart';
import '../asn1/x509_extensions.dart';
import 'ocsp_codec.dart';
import 'ocsp_models.dart';

/// Exception thrown by OCSP client on transport/protocol errors.
class OcspException implements Exception {
  OcspException(this.message);
  final String message;

  @override
  String toString() => 'OcspException: $message';
}

/// OCSP client for RFC 6960 Online Certificate Status Protocol.
class OcspClient {
  OcspClient({
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 15),
  }) : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;
  final Duration timeout;

  /// Sends an OCSPRequest to [responderUrl]. Throws OcspException on transport errors.
  /// Returns OcspResponse with status != successful on protocol failures.
  Future<OcspResponse> sendRequest(
    Uri responderUrl,
    Uint8List requestDer,
  ) async {
    try {
      final response = await _httpClient
          .post(
            responderUrl,
            headers: {
              'Content-Type': 'application/ocsp-request',
              'Accept': 'application/ocsp-response',
            },
            body: requestDer,
          )
          .timeout(timeout);

      if (response.statusCode != 200) {
        final bodySnippet = response.body.length > 100
            ? response.body.substring(0, 100)
            : response.body;
        throw OcspException('HTTP ${response.statusCode}: $bodySnippet');
      }

      final contentType = response.headers['content-type'] ?? '';
      if (!contentType.contains('application/ocsp-response') &&
          !contentType.contains('application/octet-stream')) {
        throw OcspException('Unexpected Content-Type: $contentType');
      }

      return parseOcspResponse(response.bodyBytes);
    } on OcspException {
      rethrow;
    } catch (e) {
      throw OcspException('Transport error: $e');
    }
  }

  /// Convenience: builds CertID for [certDer] vs [issuerDer], generates nonce,
  /// extracts OCSP URL from cert AIA, sends request, validates nonce echo,
  /// validates that the response has a SingleResponse matching the requested CertID.
  /// Returns OcspResponse. If no AIA OCSP URL is in the cert, returns a synthetic
  /// response with status = internalError and rawResponse = null.
  Future<OcspResponse> checkCertificate({
    required Uint8List certDer,
    required Uint8List issuerDer,
    String hashAlgorithmOid = Oid.sha1,
    Uri? overrideResponderUrl,
  }) async {
    // Determine responder URL
    Uri? responderUrl = overrideResponderUrl;
    if (responderUrl == null) {
      final urls = X509Extensions.ocspUrls(certDer);
      if (urls.isEmpty) {
        return OcspResponse(status: OcspResponseStatus.internalError);
      }
      try {
        responderUrl = Uri.parse(urls.first);
      } catch (e) {
        return OcspResponse(status: OcspResponseStatus.internalError);
      }
    }

    // Build CertID
    final certId = _buildCertId(certDer, issuerDer, hashAlgorithmOid);
    if (certId == null) {
      return OcspResponse(status: OcspResponseStatus.internalError);
    }

    // Generate nonce
    final nonce = _generateNonce();

    // Encode request
    final requestDer = encodeOcspRequest(certIds: [certId], nonce: nonce);

    // Send request
    final response = await sendRequest(responderUrl, requestDer);

    // Validate response
    if (!response.isSuccessful) {
      return response;
    }

    // Validate nonce echo (if present in response, must match)
    if (response.respNonce != null && !bytesEqual(response.respNonce!, nonce)) {
      return OcspResponse(status: OcspResponseStatus.internalError);
    }

    // Validate that at least one SingleResponse matches the requested CertID
    bool foundMatch = false;
    for (final singleResp in response.responses) {
      if (_certIdsEqual(singleResp.certId, certId)) {
        foundMatch = true;
        break;
      }
    }

    if (!foundMatch) {
      return OcspResponse(status: OcspResponseStatus.internalError);
    }

    return response;
  }

  /// Build CertID from cert and issuer DER.
  OcspCertId? _buildCertId(
    Uint8List certDer,
    Uint8List issuerDer,
    String hashAlgorithmOid,
  ) {
    try {
      // Parse issuer cert
      final issuerObj = derDecode(issuerDer);
      if (issuerObj is! ASN1Sequence ||
          issuerObj.elements == null ||
          issuerObj.elements!.isEmpty) {
        return null;
      }

      // Extract issuer's tbsCertificate
      final issuerTbsCert = issuerObj.elements![0];
      if (issuerTbsCert is! ASN1Sequence || issuerTbsCert.elements == null) {
        return null;
      }

      // Extract issuer subject (Name) — it's the 6th element (index 5) in TBSCertificate
      // TBSCertificate: version[0], serialNumber, signature, issuer, validity, subject, subjectPublicKeyInfo, ...
      if (issuerTbsCert.elements!.length < 7) {
        return null;
      }

      final issuerSubjectObj = issuerTbsCert.elements![5];
      final issuerSubjectDer = derEncode(issuerSubjectObj);
      final issuerNameHash = hashOf(issuerSubjectDer, hashAlgorithmOid);

      // Extract issuer's subjectPublicKeyInfo (7th element, index 6)
      final issuerSpkiObj = issuerTbsCert.elements![6];
      if (issuerSpkiObj is! ASN1Sequence ||
          issuerSpkiObj.elements == null ||
          issuerSpkiObj.elements!.length < 2) {
        return null;
      }

      // subjectPublicKeyInfo: algorithm, subjectPublicKey (BIT STRING)
      final issuerSpkBitStringObj = issuerSpkiObj.elements![1];
      if (issuerSpkBitStringObj is! ASN1BitString) {
        return null;
      }

      // Extract BIT STRING value (skip the unused-bits byte)
      final issuerSpkBytes = issuerSpkBitStringObj.stringValues;
      if (issuerSpkBytes == null || issuerSpkBytes.isEmpty) {
        return null;
      }
      final issuerKeyHash = hashOf(
        Uint8List.fromList(issuerSpkBytes),
        hashAlgorithmOid,
      );

      // Parse subject cert
      final certObj = derDecode(certDer);
      if (certObj is! ASN1Sequence ||
          certObj.elements == null ||
          certObj.elements!.isEmpty) {
        return null;
      }

      // Extract subject's tbsCertificate
      final certTbsCert = certObj.elements![0];
      if (certTbsCert is! ASN1Sequence || certTbsCert.elements == null) {
        return null;
      }

      // Extract serialNumber (2nd element, index 1)
      if (certTbsCert.elements!.length < 2) {
        return null;
      }

      final serialNumberObj = certTbsCert.elements![1];
      if (serialNumberObj is! ASN1Integer) {
        return null;
      }

      final serialNumber = serialNumberObj.integer ?? BigInt.zero;

      return OcspCertId(
        hashAlgorithmOid: hashAlgorithmOid,
        issuerNameHash: issuerNameHash,
        issuerKeyHash: issuerKeyHash,
        serialNumber: serialNumber,
      );
    } catch (e) {
      return null;
    }
  }

  /// Generate a 16-byte random nonce.
  Uint8List _generateNonce() {
    final random = Random.secure();
    final nonce = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      nonce[i] = random.nextInt(256);
    }
    return nonce;
  }

  /// Check if two CertIDs are equal.
  bool _certIdsEqual(OcspCertId a, OcspCertId b) {
    return a.hashAlgorithmOid == b.hashAlgorithmOid &&
        bytesEqual(a.issuerNameHash, b.issuerNameHash) &&
        bytesEqual(a.issuerKeyHash, b.issuerKeyHash) &&
        a.serialNumber == b.serialNumber;
  }
}
