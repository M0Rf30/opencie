// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/features/sign/utils/signature_image_generator.dart';

void main() {
  group('generateDefaultSignatureImage includeDate', () {
    final when = DateTime(2026, 5, 4, 12, 30);

    testWidgets('omits the date line when includeDate is false', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final withDate = await generateDefaultSignatureImage(signingDate: when);
        final withDateAgain = await generateDefaultSignatureImage(
          signingDate: when,
        );
        final withoutDate = await generateDefaultSignatureImage(
          signingDate: when,
          includeDate: false,
        );
        final otherDateHidden = await generateDefaultSignatureImage(
          signingDate: DateTime(2031, 1, 2, 3, 4),
          includeDate: false,
        );

        // Deterministic rendering.
        expect(withDate, withDateAgain);
        // An extra text line is drawn when the date is included…
        expect(withDate, isNot(withoutDate));
        // …and the date has no influence at all once omitted.
        expect(withoutDate, otherDateHidden);
      });
    });
  });
}
