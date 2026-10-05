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
import '../ltv/asn1/der.dart' show bytesEqual;
import '../ltv/asn1/oids.dart' show Oid;
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

/// Post-sign step that upgrades a freshly signed file in place: PAdES →
/// DocTimeStamp, DSS, DocTimeStamp (B-T → B-LT → B-LTA); CAdES → signature
/// time-stamp, certificate/revocation values, archive time-stamp.
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

      // An invalid policy OID is a configuration error: report it as a TSA
      // failure before any network access.
      final String? policyOid;
      try {
        policyOid = normalizeTsaPolicyOid(settings.tsa.policyOid);
      } on TspException catch (e) {
        return SignatureUpgradeResult(
          warning: SignatureUpgradeWarning.timestampFailed,
          detail: e.message,
        );
      }

      client = _httpClientFactory(settings);
      final tsp = TspClient(httpClient: client);

      // 1. Validation material for the signer chain (best effort: the
      //    timestamp is still useful when revocation evidence is
      //    unreachable).
      String? revocationProblem;
      CollectedValidationMaterial? material;
      ValidationMaterialCollector? collector;
      try {
        collector = _collectorFactory(client);
        final signerCerts = _signerCertificates(original, format);
        material = await collector.collect(
          signerCerts,
          settings.validationType,
        );
        if (!material.hasRevocationData) {
          revocationProblem = 'no OCSP/CRL evidence could be retrieved';
        }
      } catch (e) {
        debugPrint('LtvSignatureUpgrader.upgrade: validation data failed ($e)');
        revocationProblem = e.toString();
      }

      // 2. Upgrade + timestamp (primary TSA, then the configured fallback).
      //    Nothing touches the file until a whole attempt succeeded: an
      //    attempt that fails half way (e.g. the second PAdES document
      //    time-stamp) is discarded and the next TSA restarts from the
      //    untouched original.
      Object? lastError;
      _UpgradeOutcome? outcome;
      for (final url in urls) {
        try {
          outcome = await _upgradeWith(
            original,
            format,
            tsp,
            url,
            policyOid: policyOid,
            validationType: settings.validationType,
            collector: collector,
            signerMaterial: material,
          );
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

      // The warning covers both the signer chain and the chain of the TSA
      // that signed the first time-stamp.
      final revocationEmbedded = outcome.signerRevocationEmbedded;
      final String? detail = revocationEmbedded
          ? outcome.timestampProblem
          : (outcome.problem ??
                revocationProblem ??
                outcome.timestampProblem ??
                'no OCSP/CRL evidence was embedded');
      return SignatureUpgradeResult(
        timestamped: true,
        revocationEmbedded: revocationEmbedded,
        warning: detail == null
            ? null
            : SignatureUpgradeWarning.revocationUnavailable,
        detail: detail,
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

  /// One full attempt against a single TSA.
  ///
  /// CAdES: B-T (signature time-stamp) → LT (certificate-values +
  /// revocation-values for the signer chain and the TSA chain) → LTA
  /// (archive time-stamp).
  ///
  /// PAdES (ETSI EN 319 142-1): signature → DocTimeStamp #1 (B-T) → DSS
  /// revision with the signer chain and the TSA #1 chain (B-LT) →
  /// DocTimeStamp #2 (B-LTA). Only incremental updates are appended, so the
  /// signed revision stays valid. Limitation: classic xref tables only; a
  /// PDF with xref streams fails the attempt and stays untouched.
  ///
  /// A TSA failure throws; a failure to gather or embed validation data is
  /// reported in the outcome and does not abort.
  Future<_UpgradeOutcome> _upgradeWith(
    Uint8List original,
    SignatureFormat format,
    TspClient tsp,
    Uri url, {
    required String? policyOid,
    required ValidationType validationType,
    required ValidationMaterialCollector? collector,
    required CollectedValidationMaterial? signerMaterial,
  }) {
    switch (format) {
      case SignatureFormat.pades:
        return _upgradePades(
          original,
          tsp,
          url,
          policyOid,
          validationType,
          collector,
          signerMaterial,
        );
      case SignatureFormat.cades:
        return _upgradeCades(
          original,
          tsp,
          url,
          policyOid,
          validationType,
          collector,
          signerMaterial,
        );
      case SignatureFormat.xades:
        throw UnsupportedError('XAdES timestamps are not supported');
    }
  }

  Future<_UpgradeOutcome> _upgradePades(
    Uint8List original,
    TspClient tsp,
    Uri url,
    String? policyOid,
    ValidationType validationType,
    ValidationMaterialCollector? collector,
    CollectedValidationMaterial? signerMaterial,
  ) async {
    final stamper = PadesLtaUpgrader(
      tspClient: tsp,
      tspUrl: url,
      contentsReserveBytes: _padesTimestampReserve,
      policyOid: policyOid,
    );

    // B-T: the first document time-stamp covers the signed revision.
    final first = await stamper.upgradeWithToken(original);
    var current = first.bytes;

    // B-LT: validation material for the signer AND the TSA #1 chain.
    final tsaCerts = _tokenCertificates(first.token);
    final tsa = await _collectTsaChain(collector, tsaCerts, validationType);
    final merged = (signerMaterial ?? const CollectedValidationMaterial())
        .merge(tsa.material);

    var signerEmbedded = false;
    String? problem;
    var dssWritten = false;
    if (!merged.isEmpty) {
      try {
        current = PadesLtUpgrader().upgrade(
          current,
          PdfValidationMaterial(
            certificates: merged.certificates,
            crls: merged.crls,
            ocspResponses: merged.ocspResponses,
          ),
        );
        dssWritten = true;
        signerEmbedded = signerMaterial?.hasRevocationData ?? false;
      } catch (e) {
        debugPrint('LtvSignatureUpgrader: validation data not embedded ($e)');
        problem = e.toString();
      }
    }

    // B-LTA: the second document time-stamp covers the DSS. Without a DSS
    // there is nothing to protect, so the B-T result stands. A TSA failure
    // here throws and discards the whole attempt.
    if (dssWritten) {
      current = await stamper.upgrade(current);
    }

    return _UpgradeOutcome(
      current,
      signerRevocationEmbedded: signerEmbedded,
      problem: problem,
      timestampProblem: tsa.problem,
    );
  }

  Future<_UpgradeOutcome> _upgradeCades(
    Uint8List original,
    TspClient tsp,
    Uri url,
    String? policyOid,
    ValidationType validationType,
    ValidationMaterialCollector? collector,
    CollectedValidationMaterial? signerMaterial,
  ) async {
    // A signature that already carries archive time-stamps is being renewed:
    // its existing unsigned attributes are covered by those stamps and must
    // stay byte-identical, so neither B-T nor LT touches it again.
    final renewal = CadesSignedData.parse(
      original,
    ).archiveTimeStampTokens.isNotEmpty;

    var current = original;
    var signerEmbedded = false;
    String? problem;
    String? timestampProblem;

    if (!renewal) {
      // B-T: signature-time-stamp over the signature value.
      current = await CadesTUpgrader(
        tspClient: tsp,
        tspUrl: url,
        policyOid: policyOid,
      ).upgrade(current);

      // LT: certificate-values / revocation-values for the signer AND the
      // TSA that issued the signature-time-stamp (whose certificates live
      // inside the token, not in SignedData.certificates).
      final tsaCerts = CadesSignedData.parse(
        current,
      ).signatureTimeStampCertificates;
      final tsa = await _collectTsaChain(collector, tsaCerts, validationType);
      timestampProblem = tsa.problem;
      final merged = (signerMaterial ?? const CollectedValidationMaterial())
          .merge(tsa.material);

      try {
        final outer = CadesSignedData.parse(current).embeddedCertificates;
        // certificate-values omits what SignedData.certificates already has;
        // skip the step when nothing new would be written.
        final hasNewCerts = merged.certificates.any(
          (c) => !outer.any((o) => bytesEqual(o, c)),
        );
        if (merged.hasRevocationData || hasNewCerts) {
          current = CadesLtUpgrader().upgrade(
            current,
            ValidationMaterial(
              certificates: merged.certificates,
              crls: merged.crls,
              ocspResponses: merged.ocspResponses,
            ),
          );
          signerEmbedded = signerMaterial?.hasRevocationData ?? false;
        }
      } catch (e) {
        debugPrint('LtvSignatureUpgrader: validation data not embedded ($e)');
        problem = e.toString();
      }
    } else {
      // The earlier run already embedded what it could for the signer.
      final existing = CadesSignedData.parse(original);
      signerEmbedded =
          existing.getUnsignedAttribute(Oid.revocationValues) != null ||
          existing.signedDataCrlTlvs.isNotEmpty;
    }

    // LTA: archive-time-stamp-v3 (ETSI EN 319 122-1 §5.5.3) over everything
    // above; on renewal it is appended after the existing ones, preceded by
    // validation data for their TSAs. A TSA failure here throws and discards
    // the whole attempt.
    current = await CadesLtaUpgrader(
      tspClient: tsp,
      tspUrl: url,
      policyOid: policyOid,
      previousTimestampValidation: (previousTsaCerts) async {
        final chain = await _collectTsaChain(
          collector,
          previousTsaCerts,
          validationType,
        );
        timestampProblem ??= chain.problem;
        return ValidationMaterial(
          certificates: chain.material.certificates,
          crls: chain.material.crls,
          ocspResponses: chain.material.ocspResponses,
        );
      },
    ).upgrade(current);

    return _UpgradeOutcome(
      current,
      signerRevocationEmbedded: signerEmbedded,
      problem: problem,
      timestampProblem: timestampProblem,
    );
  }

  /// Certificates inside a DER TimeStampToken (empty when unparsable).
  List<Uint8List> _tokenCertificates(Uint8List token) {
    try {
      return CadesSignedData.parse(token).embeddedCertificates;
    } catch (e) {
      debugPrint('LtvSignatureUpgrader._tokenCertificates: $e');
      return const [];
    }
  }

  /// Chain + OCSP/CRL for the TSA that signed a time-stamp. Never throws.
  /// [problem] is set when the TSA chain could not be fully covered; the
  /// token's own certificates are always part of the returned material.
  Future<({CollectedValidationMaterial material, String? problem})>
  _collectTsaChain(
    ValidationMaterialCollector? collector,
    List<Uint8List> tsaCerts,
    ValidationType type,
  ) async {
    if (tsaCerts.isEmpty) {
      return (
        material: const CollectedValidationMaterial(),
        problem: 'the timestamp token carries no TSA certificate',
      );
    }
    final own = CollectedValidationMaterial(certificates: tsaCerts);
    if (collector == null) {
      return (
        material: own,
        problem: 'no revocation evidence for the timestamp authority',
      );
    }
    try {
      final m = await collector.collect(tsaCerts, type);
      return (
        material: own.merge(m),
        problem: m.hasRevocationData
            ? null
            : 'no OCSP/CRL evidence could be retrieved for the timestamp '
                  'authority certificate chain',
      );
    } catch (e) {
      debugPrint('LtvSignatureUpgrader._collectTsaChain: $e');
      return (
        material: own,
        problem: 'timestamp authority validation data failed: $e',
      );
    }
  }
}

class _UpgradeOutcome {
  const _UpgradeOutcome(
    this.bytes, {
    required this.signerRevocationEmbedded,
    this.problem,
    this.timestampProblem,
  });
  final Uint8List bytes;

  /// OCSP/CRL evidence for the signer chain was written into the file.
  final bool signerRevocationEmbedded;

  /// Why the validation material could not be embedded, if it could not.
  final String? problem;

  /// Why the TSA #1 chain is not fully covered by revocation evidence.
  final String? timestampProblem;
}
