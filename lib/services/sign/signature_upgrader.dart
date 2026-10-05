// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:io';

import 'package:convert/convert.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../models/proxy_config.dart';
import '../../models/signature_options.dart';
import '../../models/tsa_config.dart';
import '../../providers/settings_provider.dart'
    show AppSettings, ValidationType;
import '../ltv/cades/cades_lt.dart';
import '../ltv/cades/cades_lta.dart';
import '../ltv/cades/cades_models.dart';
import '../ltv/cades/cades_parser.dart';
import '../ltv/cades/cades_t.dart';
import '../ltv/pades/pades_lt.dart';
import '../ltv/pades/pades_lta.dart';
import '../ltv/pades/pdf_models.dart';
import '../ltv/pades/pdf_reader.dart';
import '../ltv/tsp/tsp_client.dart';
import 'upgrade_http_client.dart';
import 'validation_material_collector.dart';

/// Why the post-sign upgrade did not fully succeed. The native signature is
/// always still valid and kept on disk.
enum SignatureUpgradeWarning {
  /// No timestamp was applied; the signed file is unchanged.
  timestampFailed,

  /// The timestamp was applied, but no OCSP/CRL evidence could be embedded,
  /// so the signature is not long-term verifiable offline.
  revocationUnavailable,
}

/// The slice of [AppSettings] the upgrade needs.
class SignatureUpgradeSettings {
  const SignatureUpgradeSettings({
    this.tsa = const TsaConfig(),
    this.proxy = const ProxyConfig(),
    this.validationType = ValidationType.ocspFirst,
  });

  factory SignatureUpgradeSettings.fromAppSettings(AppSettings s) {
    return SignatureUpgradeSettings(
      tsa: s.tsaConfig,
      proxy: s.proxyConfig,
      validationType: s.validationType,
    );
  }

  final TsaConfig tsa;
  final ProxyConfig proxy;
  final ValidationType validationType;
}

/// Outcome of [SignatureUpgrader.upgrade].
class SignatureUpgradeResult {
  const SignatureUpgradeResult({
    this.timestamped = false,
    this.revocationEmbedded = false,
    this.warning,
    this.detail,
  });

  /// A trusted timestamp was written into the signed file.
  final bool timestamped;

  /// OCSP and/or CRL evidence was written into the signed file.
  final bool revocationEmbedded;

  final SignatureUpgradeWarning? warning;

  /// Technical reason for [warning], for logs and the UI.
  final String? detail;

  bool get hasWarning => warning != null;
}

/// Post-sign step that upgrades a freshly signed file (PAdES → LT + document
/// timestamp, CAdES → LT + archive timestamp) in place.
///
/// Implementations MUST NOT throw and MUST leave [path] untouched (still the
/// valid native signature) whenever no timestamp could be applied.
abstract class SignatureUpgrader {
  Future<SignatureUpgradeResult> upgrade({
    required String path,
    required SignatureFormat format,
    required SignatureUpgradeSettings settings,
  });
}

/// Production [SignatureUpgrader] built on the pure-Dart LTV stack
/// (`services/ltv/**`).
class LtvSignatureUpgrader implements SignatureUpgrader {
  LtvSignatureUpgrader({
    http.Client Function(SignatureUpgradeSettings settings)? httpClientFactory,
    ValidationMaterialCollector Function(http.Client client)? collectorFactory,
  }) : _httpClientFactory = httpClientFactory ?? _defaultHttpClient,
       _collectorFactory = collectorFactory ?? ValidationMaterialCollector.http;

  final http.Client Function(SignatureUpgradeSettings settings)
  _httpClientFactory;
  final ValidationMaterialCollector Function(http.Client client)
  _collectorFactory;

  /// /Contents space reserved for the PAdES document timestamp (hex chars).
  /// Qualified TSAs return tokens carrying their full certificate chain.
  static const _padesTimestampReserve = 32768;

  static http.Client _defaultHttpClient(SignatureUpgradeSettings s) =>
      buildUpgradeHttpClient(proxy: s.proxy, tsa: s.tsa);

  @override
  Future<SignatureUpgradeResult> upgrade({
    required String path,
    required SignatureFormat format,
    required SignatureUpgradeSettings settings,
  }) async {
    if (!format.supportsTimestamp) {
      return const SignatureUpgradeResult(
        warning: SignatureUpgradeWarning.timestampFailed,
        detail: 'timestamps are not supported for this format',
      );
    }

    http.Client? client;
    File? tmp;
    try {
      final original = await File(path).readAsBytes();

      final urls = _tsaUrls(settings.tsa);
      client = _httpClientFactory(settings);
      final tsp = TspClient(httpClient: client);

      // 1. Validation material (best effort: the timestamp is still useful
      //    when revocation evidence is unreachable).
      String? revocationProblem;
      CollectedValidationMaterial? material;
      try {
        final signerCerts = _signerCertificates(original, format);
        material = await _collectorFactory(
          client,
        ).collect(signerCerts, settings.validationType);
        if (!material.hasRevocationData) {
          revocationProblem = 'no OCSP/CRL evidence could be retrieved';
        }
      } catch (e) {
        debugPrint('LtvSignatureUpgrader.upgrade: validation data failed ($e)');
        revocationProblem = e.toString();
      }

      // 2. Upgrade + timestamp (primary TSA, then the configured fallback).
      //    Nothing touches the file until a whole attempt succeeded.
      Object? lastError;
      _UpgradeOutcome? outcome;
      for (final url in urls) {
        try {
          outcome = await _upgradeWith(original, format, tsp, url, material);
          break;
        } catch (e) {
          debugPrint('LtvSignatureUpgrader.upgrade: TSA $url failed ($e)');
          lastError = e;
        }
      }
      if (outcome == null) {
        return SignatureUpgradeResult(
          warning: SignatureUpgradeWarning.timestampFailed,
          detail: lastError?.toString() ?? 'no TSA configured',
        );
      }

      // 3. Atomic replace: temp file in the same directory, then rename.
      tmp = File('$path.upgrade-${DateTime.now().microsecondsSinceEpoch}.tmp');
      await tmp.writeAsBytes(outcome.bytes, flush: true);
      await tmp.rename(path);
      tmp = null;

      final revocationEmbedded = outcome.revocationEmbedded;
      final problem = outcome.problem ?? revocationProblem;
      return SignatureUpgradeResult(
        timestamped: true,
        revocationEmbedded: revocationEmbedded,
        warning: revocationEmbedded
            ? null
            : SignatureUpgradeWarning.revocationUnavailable,
        detail: revocationEmbedded ? null : problem,
      );
    } catch (e) {
      debugPrint('LtvSignatureUpgrader.upgrade: failed ($e)');
      return SignatureUpgradeResult(
        warning: SignatureUpgradeWarning.timestampFailed,
        detail: e.toString(),
      );
    } finally {
      client?.close();
      if (tmp != null) {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {
          // Intentional: best-effort cleanup of a temp file we created.
        }
      }
    }
  }

  List<Uri> _tsaUrls(TsaConfig tsa) {
    final urls = <Uri>[];
    for (final raw in [tsa.serverUrl, tsa.fallbackUrl]) {
      final uri = Uri.tryParse(raw.trim());
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) continue;
      if (uri.scheme != 'http' && uri.scheme != 'https') continue;
      if (!urls.contains(uri)) urls.add(uri);
    }
    if (urls.isEmpty) {
      throw const FormatException('invalid TSA URL');
    }
    return urls;
  }

  /// Certificates embedded in the signature CMS (empty when unparsable).
  List<Uint8List> _signerCertificates(Uint8List bytes, SignatureFormat f) {
    try {
      final Uint8List cms;
      switch (f) {
        case SignatureFormat.pades:
          final range = PdfReader(bytes).findSignatureContentsRange();
          if (range == null) return const [];
          final hexStr = String.fromCharCodes(
            bytes.sublist(range.contentsStart, range.contentsEnd),
          ).replaceAll(RegExp(r'\s'), '');
          cms = Uint8List.fromList(hex.decode(hexStr));
        case SignatureFormat.cades:
          cms = bytes;
        case SignatureFormat.xades:
          return const [];
      }
      return CadesSignedData.parse(cms).embeddedCertificates;
    } catch (e) {
      debugPrint('LtvSignatureUpgrader._signerCertificates: $e');
      return const [];
    }
  }

  /// Embeds certificates + revocation evidence (PAdES DSS / CAdES
  /// revocation-values). Returns null when there is nothing to embed.
  Uint8List? _applyLongTermValidation(
    Uint8List bytes,
    SignatureFormat format,
    CollectedValidationMaterial m,
  ) {
    if (m.certificates.isEmpty && !m.hasRevocationData) return null;
    switch (format) {
      case SignatureFormat.pades:
        return PadesLtUpgrader().upgrade(
          bytes,
          PdfValidationMaterial(
            certificates: m.certificates,
            crls: m.crls,
            ocspResponses: m.ocspResponses,
          ),
        );
      case SignatureFormat.cades:
        // Without revocation evidence CAdES-LT adds only certificate-values,
        // which the signature already embeds; skip rather than fail.
        if (!m.hasRevocationData) return null;
        return CadesLtUpgrader().upgrade(
          bytes,
          ValidationMaterial(
            certificates: m.certificates,
            crls: m.crls,
            ocspResponses: m.ocspResponses,
          ),
        );
      case SignatureFormat.xades:
        return null;
    }
  }

  /// One full attempt against a single TSA. CAdES: B-T (signature
  /// time-stamp) → LT (revocation-values) → LTA (archive time-stamp).
  /// PAdES: DSS → document time-stamp. A TSA failure throws; a failure to
  /// embed validation data is reported in the result and does not abort.
  Future<_UpgradeOutcome> _upgradeWith(
    Uint8List original,
    SignatureFormat format,
    TspClient tsp,
    Uri url,
    CollectedValidationMaterial? material,
  ) async {
    var current = original;
    if (format == SignatureFormat.cades) {
      current = await CadesTUpgrader(
        tspClient: tsp,
        tspUrl: url,
      ).upgrade(current);
    }

    var embedded = false;
    String? problem;
    if (material != null) {
      try {
        final withLt = _applyLongTermValidation(current, format, material);
        if (withLt != null) {
          current = withLt;
          embedded = material.hasRevocationData;
        }
      } catch (e) {
        debugPrint('LtvSignatureUpgrader: validation data not embedded ($e)');
        problem = e.toString();
      }
    }

    final stamped = await _timestamp(current, format, tsp, url);
    return _UpgradeOutcome(stamped, embedded, problem);
  }

  Future<Uint8List> _timestamp(
    Uint8List bytes,
    SignatureFormat format,
    TspClient tsp,
    Uri url,
  ) {
    switch (format) {
      case SignatureFormat.pades:
        return PadesLtaUpgrader(
          tspClient: tsp,
          tspUrl: url,
          contentsReserveBytes: _padesTimestampReserve,
        ).upgrade(bytes);
      case SignatureFormat.cades:
        return CadesLtaUpgrader(tspClient: tsp, tspUrl: url).upgrade(bytes);
      case SignatureFormat.xades:
        throw UnsupportedError('XAdES timestamps are not supported');
    }
  }
}

class _UpgradeOutcome {
  const _UpgradeOutcome(this.bytes, this.revocationEmbedded, this.problem);
  final Uint8List bytes;
  final bool revocationEmbedded;
  final String? problem;
}
