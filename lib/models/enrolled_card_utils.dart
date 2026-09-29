// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

/// Pure helper functions for combining [EnrolledCard] entries.
///
/// Kept free of Flutter/Riverpod imports so they can be unit-tested without
/// a widget test harness.
library;

import 'enrolled_card.dart';

/// Merges [incoming] into [existing] (same `pan`), keeping [existing]'s
/// non-null fields when [incoming] doesn't provide a value.
///
/// This lets a partial re-enrolment (e.g. chip read failed and only the
/// certificate was refreshed) avoid wiping out previously-captured data
/// such as the MRZ photo.
EnrolledCard mergeEnrolledCard(EnrolledCard existing, EnrolledCard incoming) {
  return EnrolledCard(
    pan: incoming.pan,
    name: incoming.name.isNotEmpty ? incoming.name : existing.name,
    serial: incoming.serial.isNotEmpty ? incoming.serial : existing.serial,
    notBefore: incoming.notBefore ?? existing.notBefore,
    notAfter: incoming.notAfter ?? existing.notAfter,
    issuer: incoming.issuer ?? existing.issuer,
    subject: incoming.subject ?? existing.subject,
    certSerial: incoming.certSerial ?? existing.certSerial,
    keyAlgorithm: incoming.keyAlgorithm ?? existing.keyAlgorithm,
    mrzSurname: incoming.mrzSurname ?? existing.mrzSurname,
    mrzGivenNames: incoming.mrzGivenNames ?? existing.mrzGivenNames,
    mrzExpiry: incoming.mrzExpiry ?? existing.mrzExpiry,
    photoBytes: incoming.photoBytes ?? existing.photoBytes,
    lastUsed: incoming.lastUsed ?? existing.lastUsed,
  );
}

/// Returns a copy of [cards] with [card] inserted or, if a card with the
/// same `pan` already exists, merged into the existing entry in place
/// (list order is preserved either way).
List<EnrolledCard> upsertEnrolledCard(
  List<EnrolledCard> cards,
  EnrolledCard card,
) {
  final result = List<EnrolledCard>.from(cards);
  final idx = result.indexWhere((c) => c.pan == card.pan);
  if (idx >= 0) {
    result[idx] = mergeEnrolledCard(result[idx], card);
  } else {
    result.add(card);
  }
  return result;
}

/// Stamps `lastUsed` on the single enrolled card, if — and only if —
/// exactly one card is enrolled (the PAN used for a sign/timestamp
/// operation isn't always known at the call site, but with a single
/// enrolled card there's no ambiguity).
///
/// Returns [cards] unchanged (same instance) when there isn't exactly one
/// card, so callers can skip a no-op provider update by comparing
/// identity.
List<EnrolledCard> markCardUsed(List<EnrolledCard> cards, [DateTime? at]) {
  if (cards.length != 1) return cards;
  return [cards[0].copyWith(lastUsed: at ?? DateTime.now())];
}
