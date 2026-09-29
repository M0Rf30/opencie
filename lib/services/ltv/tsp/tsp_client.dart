// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../asn1/der.dart';
import '../asn1/oids.dart';
import 'tsp_codec.dart';
import 'tsp_models.dart';

/// HTTP client for RFC 3161 Time-Stamp Authorities.
class TspClient {
  TspClient({
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 30),
    this.maxBytes = 1024 * 1024, // 1 MB cap — real TST tokens are KB-sized
  }) : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;
  final Duration timeout;

  /// Rejects responses larger than this before parsing, so a malicious or
  /// misbehaving TSA can't force unbounded buffering of an untrusted body
  /// (mirrors CrlClient's `maxBytes` cap).
  final int maxBytes;

  /// Sends a TimeStampReq to [url] and returns the parsed response.
  /// Throws TspException on transport errors. Returns a TspResponse with
  /// status = rejection on protocol-level failures.
  Future<TspResponse> requestTimestamp(Uri url, TspRequest req) async {
    final body = encodeTspRequest(req);
    try {
      final resp = await _httpClient
          .post(
            url,
            headers: const {
              'Content-Type': 'application/timestamp-query',
              'Accept': 'application/timestamp-reply',
            },
            body: body,
          )
          .timeout(timeout);

      if (resp.statusCode != 200) {
        throw TspException('HTTP ${resp.statusCode}: ${resp.body}');
      }

      final ct = resp.headers['content-type']?.toLowerCase() ?? '';
      if (ct.isNotEmpty &&
          !ct.contains('application/timestamp-reply') &&
          !ct.contains('application/octet-stream')) {
        throw TspException('Unexpected content-type: $ct');
      }

      if (resp.bodyBytes.length > maxBytes) {
        throw TspException(
          'TSA response from $url exceeds max size ($maxBytes bytes)',
        );
      }

      return parseTspResponse(resp.bodyBytes);
    } on TimeoutException {
      throw TspException('Request timed out after ${timeout.inSeconds}s');
    }
  }

  /// Convenience: hashes [data] with [hashAlgorithmOid] (default SHA-256), generates
  /// a random 8-byte nonce, and requests a timestamp. Validates the response
  /// nonce + messageImprint match what we sent.
  Future<TspResponse> timestampData(
    Uri url,
    Uint8List data, {
    String hashAlgorithmOid = Oid.sha256,
    bool requestCert = false,
    String? policyOid,
  }) async {
    // 1. Compute hash
    final hash = hashOf(data, hashAlgorithmOid);

    // 2. Generate random 8-byte nonce
    final nonce = _generateNonce(8);

    // 3. Build request
    final req = TspRequest(
      messageImprintHash: hash,
      hashAlgorithmOid: hashAlgorithmOid,
      nonce: nonce,
      reqCertReq: requestCert,
      policyOid: policyOid,
    );

    // 4. Send request
    final resp = await requestTimestamp(url, req);

    // 5. Validate response
    if (!resp.isSuccess) {
      return resp;
    }

    // 6. Verify nonce — mandatory since timestampData always sends one
    // (RFC 3161 §2.4.2: a TSA that received a nonce and omits/mismatches it
    // must not be trusted; treating a missing nonce as "no check needed"
    // defeats the whole anti-replay purpose of sending one).
    if (resp.respNonce == null || !bytesEqual(resp.respNonce!, nonce)) {
      return TspResponse(
        status: TspStatus.rejection,
        statusStrings: [
          resp.respNonce == null
              ? 'nonce missing from TSA response (nonce was sent in request)'
              : 'nonce mismatch: sent ${nonce.length} bytes, got ${resp.respNonce!.length} bytes',
        ],
      );
    }

    // 7. Verify messageImprint hash — mandatory.
    if (resp.messageImprintHash == null ||
        !bytesEqual(resp.messageImprintHash!, hash)) {
      return TspResponse(
        status: TspStatus.rejection,
        statusStrings: [
          resp.messageImprintHash == null
              ? 'messageImprint hash missing from TSTInfo'
              : 'hash mismatch: sent ${hash.length} bytes, got ${resp.messageImprintHash!.length} bytes',
        ],
      );
    }

    // 8. Verify messageImprint hash algorithm OID — mandatory.
    if (resp.messageImprintHashOid == null ||
        resp.messageImprintHashOid != hashAlgorithmOid) {
      return TspResponse(
        status: TspStatus.rejection,
        statusStrings: [
          'hash algorithm mismatch: sent $hashAlgorithmOid, got ${resp.messageImprintHashOid}',
        ],
      );
    }

    return resp;
  }

  /// Generate cryptographically random bytes.
  static Uint8List _generateNonce(int length) {
    final random = Random.secure();
    final values = List<int>.generate(length, (i) => random.nextInt(256));
    return Uint8List.fromList(values);
  }
}

/// Exception thrown by TspClient on transport or protocol errors.
class TspException implements Exception {
  TspException(this.message);
  final String message;

  @override
  String toString() => 'TspException: $message';
}
