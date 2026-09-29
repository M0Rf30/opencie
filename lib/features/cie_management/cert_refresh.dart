// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

/// Refreshes certificate fields (notAfter/notBefore/issuer/subject/
/// certSerial) for enrolled cards saved while cert enrichment previously
/// failed — e.g. cards enrolled against a legacy pkcs11 cache format that
/// couldn't produce a certificate at enrolment time.
///
/// Kept free of Flutter/Riverpod imports so it can be unit-tested with a
/// fake [CertFetcher], without touching the native library or FFI.
library;

import '../../models/enrolled_card.dart';

/// Fetches (and returns an enriched copy of) a single card's certificate
/// data. Must never throw — on failure it should return [card] unchanged
/// (this mirrors `_enrichCardWithCert`'s contract).
typedef CertFetcher = Future<EnrolledCard> Function(EnrolledCard card);

/// Returns a card if it's missing certificate data that should be
/// refreshed.
bool cardNeedsCertRefresh(EnrolledCard card) =>
    card.notAfter == null || card.certSerial == null;

/// Runs [fetchCert] once for every card in [cards] that is missing
/// certificate data (see [cardNeedsCertRefresh]), sequentially (no
/// concurrent isolate spawns).
///
/// Returns `null` when no card needed refreshing (nothing to persist),
/// otherwise the updated list in the original order.
Future<List<EnrolledCard>?> refreshMissingCertData(
  List<EnrolledCard> cards, {
  required CertFetcher fetchCert,
}) async {
  final candidates = cards.where(cardNeedsCertRefresh);
  if (candidates.isEmpty) return null;

  var changed = false;
  final result = <EnrolledCard>[];
  for (final card in cards) {
    if (!cardNeedsCertRefresh(card)) {
      result.add(card);
      continue;
    }
    final enriched = await fetchCert(card);
    if (enriched.notAfter != card.notAfter ||
        enriched.certSerial != card.certSerial) {
      changed = true;
    }
    result.add(enriched);
  }
  return changed ? result : null;
}
