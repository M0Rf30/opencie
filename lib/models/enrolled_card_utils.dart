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

/// Like [markCardUsed], but when [pan] identifies one of [cards] that card
/// is stamped — which is the right behaviour with several enrolled cards,
/// where the signer is the selected one. Falls back to [markCardUsed] when
/// [pan] is null or not enrolled.
List<EnrolledCard> markSelectedCardUsed(
  List<EnrolledCard> cards,
  String? pan, [
  DateTime? at,
]) {
  final idx = pan == null ? -1 : cards.indexWhere((c) => c.pan == pan);
  if (idx < 0) return markCardUsed(cards, at);
  final result = List<EnrolledCard>.from(cards);
  result[idx] = result[idx].copyWith(lastUsed: at ?? DateTime.now());
  return result;
}

final _fiscalCodePattern = RegExp(
  r'[A-Z]{6}\d{2}[A-Z]\d{2}[A-Z]\d{3}[A-Z]',
  caseSensitive: false,
);

/// The holder's codice fiscale as found in the certificate subject or in
/// the card serial, upper-cased; null when neither carries one.
String? cardFiscalCode(EnrolledCard card) {
  for (final source in [card.subject, card.serial]) {
    if (source == null) continue;
    final m = _fiscalCodePattern.firstMatch(source);
    if (m != null) return m.group(0)!.toUpperCase();
  }
  return null;
}

enum CardValidity { active, expiring, expired }

/// Expiry of [card]: the MRZ date when read from the chip, else the
/// certificate's notAfter. Null when neither is known.
DateTime? cardExpiry(EnrolledCard card) => card.mrzExpiry ?? card.notAfter;

/// Validity bucket of [card] at [now]: expired once past its expiry,
/// expiring within 90 days of it, active otherwise (including when the
/// expiry is unknown).
CardValidity cardValidity(EnrolledCard card, [DateTime? now]) {
  final d = cardExpiry(card);
  if (d == null) return CardValidity.active;
  final at = now ?? DateTime.now();
  if (d.isBefore(at)) return CardValidity.expired;
  if (d.isBefore(at.add(const Duration(days: 90)))) {
    return CardValidity.expiring;
  }
  return CardValidity.active;
}

/// Up to two upper-case initials from the card's display name.
String cardInitials(EnrolledCard card) {
  final parts = card.displayName
      .split(RegExp(r'\s+'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return 'C';
  final first = String.fromCharCode(parts.first.runes.first);
  final second = parts.length > 1
      ? String.fromCharCode(parts[1].runes.first)
      : '';
  return (first + second).toUpperCase();
}
