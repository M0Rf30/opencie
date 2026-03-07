// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../asn1/x509_extensions.dart';
import 'crl_codec.dart';
import 'crl_models.dart';

/// HTTP client for RFC 5280 CRL (Certificate Revocation List) fetching.
class CrlClient {
  CrlClient({
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 15),
    int maxBytes = 8 * 1024 * 1024,  // 8 MB cap
    DateTime Function() now = _defaultNow,
  })  : _httpClient = httpClient ?? http.Client(),
        _timeout = timeout,
        _maxBytes = maxBytes,
        _now = now;

  final http.Client _httpClient;
  final Duration _timeout;
  final int _maxBytes;
  final DateTime Function() _now;
  final Map<String, CrlData> _cache = {};

  /// Fetches a CRL by URL. Uses cache when fresh.
  /// Throws CrlException on transport/protocol errors.
  Future<CrlData> fetch(Uri url) async {
    final urlStr = url.toString();

    // Check cache
    final cached = _cache[urlStr];
    if (cached != null && cached.isFresh(_now())) {
      return cached;
    }

    // HTTP GET
    try {
      final response = await _httpClient.get(url).timeout(_timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw CrlException('HTTP ${response.statusCode} from $url');
      }

      // Check size
      if (response.bodyBytes.length > _maxBytes) {
        throw CrlException('CRL from $url exceeds max size ($_maxBytes bytes)');
      }

      // Convert PEM to DER if needed
      final derBytes = pemOrDerToDer(response.bodyBytes);
      if (derBytes == null) {
        throw CrlException('Invalid PEM encoding from $url');
      }

      // Parse CRL
      final crl = parseCrl(derBytes, sourceUrl: urlStr);
      if (crl == null) {
        throw CrlException('Failed to parse CRL from $url');
      }

      // Cache
      _cache[urlStr] = crl;
      return crl;
    } on CrlException {
      rethrow;
    } catch (e) {
      throw CrlException('Transport error fetching $url: $e');
    }
  }

  /// Convenience: extract CDP URLs from a cert and fetch the first CRL that succeeds.
  /// Returns null if no CDP URLs present or all fetches fail.
  Future<CrlData?> fetchForCertificate(Uint8List certDer) async {
    final urls = X509Extensions.crlUrls(certDer);
    if (urls.isEmpty) {
      return null;
    }

    for (final urlStr in urls) {
      try {
        final url = Uri.tryParse(urlStr);
        if (url == null) {
          continue;
        }
        return await fetch(url);
      } catch (e) {
        // Try next URL
        continue;
      }
    }

    return null;
  }

  /// Clears the in-memory cache (testing).
  void clearCache() {
    _cache.clear();
  }

  static DateTime _defaultNow() => DateTime.now().toUtc();
}
