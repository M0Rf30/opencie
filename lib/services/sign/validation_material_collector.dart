// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../providers/settings_provider.dart' show ValidationType;
import '../ltv/asn1/der.dart' show bytesEqual;
import '../ltv/asn1/x509_cert.dart';
import '../ltv/asn1/x509_extensions.dart';
import '../ltv/crl/crl_client.dart';
import '../ltv/crl/crl_codec.dart' show pemOrDerToDer;
import '../ltv/crl/crl_models.dart';
import '../ltv/ocsp/ocsp_client.dart';
import '../ltv/ocsp/ocsp_models.dart';

/// Source of revocation evidence for one certificate. Abstract so tests can
/// route [ValidationType] policies without network access.
abstract class RevocationSource {
  /// A successful OCSP response (with raw bytes) for [certDer], or null.
  Future<OcspResponse?> ocsp(Uint8List certDer, Uint8List issuerDer);

  /// A CRL covering [certDer] from its distribution points, or null.
  Future<CrlData?> crl(Uint8List certDer);
}

/// [RevocationSource] backed by the pure-Dart OCSP/CRL clients. Never
/// throws: any transport or protocol failure is "no evidence".
class HttpRevocationSource implements RevocationSource {
  HttpRevocationSource({
    required OcspClient ocspClient,
    required CrlClient crlClient,
  }) : _ocsp = ocspClient,
       _crl = crlClient;

  final OcspClient _ocsp;
  final CrlClient _crl;

  @override
  Future<OcspResponse?> ocsp(Uint8List certDer, Uint8List issuerDer) async {
    try {
      final r = await _ocsp.checkCertificate(
        certDer: certDer,
        issuerDer: issuerDer,
      );
      return r.isSuccessful && r.rawResponse != null ? r : null;
    } catch (e) {
      debugPrint('HttpRevocationSource.ocsp: $e');
      return null;
    }
  }

  @override
  Future<CrlData?> crl(Uint8List certDer) async {
    try {
      return await _crl.fetchForCertificate(certDer);
    } catch (e) {
      debugPrint('HttpRevocationSource.crl: $e');
      return null;
    }
  }
}

/// Certificates and revocation evidence gathered for a signer.
class CollectedValidationMaterial {
  const CollectedValidationMaterial({
    this.certificates = const [],
    this.crls = const [],
    this.ocspResponses = const [],
  });

  /// Signer certificate followed by its issuers (root included when found).
  final List<Uint8List> certificates;
  final List<CrlData> crls;
  final List<OcspResponse> ocspResponses;

  /// Whether any revocation evidence (not just certificates) was found.
  bool get hasRevocationData => crls.isNotEmpty || ocspResponses.isNotEmpty;

  /// Whether there is nothing at all (no certificates, no evidence).
  bool get isEmpty =>
      certificates.isEmpty && crls.isEmpty && ocspResponses.isEmpty;

  /// This material followed by [other]'s, without duplicates (same
  /// certificate bytes, same CRL bytes, same OCSP response bytes).
  CollectedValidationMaterial merge(CollectedValidationMaterial other) {
    final certs = <Uint8List>[...certificates];
    for (final c in other.certificates) {
      if (!certs.any((o) => bytesEqual(o, c))) certs.add(c);
    }
    final mergedCrls = <CrlData>[...crls];
    for (final c in other.crls) {
      if (!mergedCrls.any((o) => bytesEqual(o.rawCrl, c.rawCrl))) {
        mergedCrls.add(c);
      }
    }
    final mergedOcsp = <OcspResponse>[...ocspResponses];
    for (final r in other.ocspResponses) {
      final raw = r.rawResponse;
      final dup = mergedOcsp.any((o) {
        final oRaw = o.rawResponse;
        if (raw == null || oRaw == null) return identical(o, r);
        return bytesEqual(oRaw, raw);
      });
      if (!dup) mergedOcsp.add(r);
    }
    return CollectedValidationMaterial(
      certificates: certs,
      crls: mergedCrls,
      ocspResponses: mergedOcsp,
    );
  }
}

/// Builds the signer's certificate chain and fetches revocation evidence
/// according to a [ValidationType] policy:
///
/// - `ocspOnly` / `crlOnly`: only that mechanism.
/// - `ocspFirst` / `crlFirst`: that mechanism, falling back to the other for
///   each certificate that yielded nothing.
class ValidationMaterialCollector {
  ValidationMaterialCollector({
    required this.revocation,
    Future<Uint8List?> Function(Uri url)? fetchIssuer,
    this.maxChainLength = 6,
  }) : _fetchIssuer = fetchIssuer;

  /// Collector whose issuer (AIA caIssuers) fetches go through [client].
  factory ValidationMaterialCollector.http(http.Client client) {
    return ValidationMaterialCollector(
      revocation: HttpRevocationSource(
        ocspClient: OcspClient(httpClient: client),
        crlClient: CrlClient(httpClient: client),
      ),
      fetchIssuer: (url) async {
        final res = await client.get(url).timeout(const Duration(seconds: 15));
        if (res.statusCode != 200 || res.bodyBytes.length > 256 * 1024) {
          return null;
        }
        return pemOrDerToDer(res.bodyBytes);
      },
    );
  }

  final RevocationSource revocation;
  final Future<Uint8List?> Function(Uri url)? _fetchIssuer;
  final int maxChainLength;

  Future<CollectedValidationMaterial> collect(
    List<Uint8List> embeddedCerts,
    ValidationType type,
  ) async {
    final chain = await buildChain(embeddedCerts);
    if (chain.isEmpty) return const CollectedValidationMaterial();

    final crls = <CrlData>[];
    final ocsps = <OcspResponse>[];
    final wantOcsp = type != ValidationType.crlOnly;
    final wantCrl = type != ValidationType.ocspOnly;
    final ocspBeforeCrl =
        type == ValidationType.ocspOnly || type == ValidationType.ocspFirst;

    for (var i = 0; i < chain.length; i++) {
      final cert = chain[i];
      if (_isSelfSigned(cert)) continue; // roots are trust anchors
      final issuer = i + 1 < chain.length ? chain[i + 1] : null;

      Future<bool> tryOcsp() async {
        if (!wantOcsp || issuer == null) return false;
        final r = await revocation.ocsp(cert, issuer);
        if (r == null) return false;
        ocsps.add(r);
        return true;
      }

      Future<bool> tryCrl() async {
        if (!wantCrl) return false;
        final c = await revocation.crl(cert);
        if (c == null) return false;
        crls.add(c);
        return true;
      }

      if (ocspBeforeCrl) {
        if (!await tryOcsp()) await tryCrl();
      } else {
        if (!await tryCrl()) await tryOcsp();
      }
    }

    return CollectedValidationMaterial(
      certificates: chain,
      crls: _dedupeCrls(crls),
      ocspResponses: ocsps,
    );
  }

  /// Signer certificate first, then each issuer found among [embedded]
  /// (by key identifiers, then by DN) or fetched from the AIA caIssuers URL.
  @visibleForTesting
  Future<List<Uint8List>> buildChain(List<Uint8List> embedded) async {
    if (embedded.isEmpty) return const [];
    final pool = [...embedded];
    final chain = <Uint8List>[_pickSigner(pool)];

    while (chain.length < maxChainLength && !_isSelfSigned(chain.last)) {
      final current = chain.last;
      final issuer =
          _findIssuer(current, pool, chain) ?? await _fetchIssuerCert(current);
      if (issuer == null) break;
      if (!pool.any((c) => bytesEqual(c, issuer))) pool.add(issuer);
      chain.add(issuer);
    }
    return chain;
  }

  /// The embedded certificate that does not issue any other embedded one.
  Uint8List _pickSigner(List<Uint8List> pool) {
    if (pool.length == 1) return pool.first;
    for (final c in pool) {
      final issuesOther = pool.any(
        (o) => !identical(o, c) && _issuedBy(o, c) && !_isSelfSigned(o),
      );
      if (!issuesOther && !_isSelfSigned(c)) return c;
    }
    return pool.first;
  }

  Uint8List? _findIssuer(
    Uint8List cert,
    List<Uint8List> pool,
    List<Uint8List> chain,
  ) {
    for (final c in pool) {
      if (bytesEqual(c, cert)) continue;
      if (chain.any((x) => bytesEqual(x, c))) continue;
      if (_issuedBy(cert, c)) return c;
    }
    return null;
  }

  Future<Uint8List?> _fetchIssuerCert(Uint8List cert) async {
    final fetch = _fetchIssuer;
    if (fetch == null) return null;
    List<String> urls;
    try {
      urls = X509Extensions.caIssuersUrls(cert);
    } catch (_) {
      // Intentional: unparsable extensions simply mean "no AIA".
      return null;
    }
    for (final u in urls) {
      final uri = Uri.tryParse(u);
      if (uri == null) continue;
      try {
        final der = await fetch(uri);
        if (der != null && _issuedBy(cert, der)) return der;
      } catch (e) {
        debugPrint('ValidationMaterialCollector.fetchIssuer: $e');
      }
    }
    return null;
  }

  /// Whether [issuer] plausibly issued [cert]: AKI == SKI when both exist,
  /// otherwise subject(issuer) == issuer(cert).
  static bool _issuedBy(Uint8List cert, Uint8List issuer) {
    try {
      final aki = X509Extensions.authorityKeyIdentifier(cert);
      final ski = X509Extensions.subjectKeyIdentifier(issuer);
      if (aki != null && ski != null) return bytesEqual(aki, ski);
    } catch (_) {
      // Intentional: fall through to the DN comparison below.
    }
    final c = X509CertInfo.fromDer(cert);
    final i = X509CertInfo.fromDer(issuer);
    if (c?.issuer == null || i?.subject == null) return false;
    return c!.issuer == i!.subject;
  }

  static bool _isSelfSigned(Uint8List cert) {
    final info = X509CertInfo.fromDer(cert);
    if (info == null || info.subject == null || info.issuer == null) {
      return false;
    }
    return info.subject == info.issuer;
  }

  static List<CrlData> _dedupeCrls(List<CrlData> crls) {
    final out = <CrlData>[];
    for (final c in crls) {
      if (!out.any((o) => bytesEqual(o.rawCrl, c.rawCrl))) out.add(c);
    }
    return out;
  }
}
