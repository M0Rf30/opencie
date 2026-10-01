// SPDX-License-Identifier: GPL-3.0-or-later

import '../../core/l10n/app_localizations.dart';
import '../../models/enrolled_card.dart';
import '../../models/enrolled_card_utils.dart';

/// Why the Sign button is disabled, in the order the user should fix it.
enum SignBlocker { noDocument, noReader, noCard, expiredCard }

/// The first unmet requirement for signing, or null when signing can start.
///
/// Order: document, reader, card, then card expiry. [card] is the active
/// (selected) enrolled card, null when none is enrolled.
SignBlocker? firstSignBlocker({
  required bool hasDocument,
  required bool readerReady,
  required EnrolledCard? card,
  DateTime? now,
}) {
  if (!hasDocument) return SignBlocker.noDocument;
  if (!readerReady) return SignBlocker.noReader;
  if (card == null) return SignBlocker.noCard;
  if (cardValidity(card, now) == CardValidity.expired) {
    return SignBlocker.expiredCard;
  }
  return null;
}

/// One-line, localised explanation for [blocker].
String signBlockerLabel(AppLocalizations l10n, SignBlocker blocker) =>
    switch (blocker) {
      SignBlocker.noDocument => l10n.signReasonNoDocument,
      SignBlocker.noReader => l10n.signReasonNoReader,
      SignBlocker.noCard => l10n.signReasonNoCard,
      SignBlocker.expiredCard => l10n.signReasonExpiredCard,
    };
