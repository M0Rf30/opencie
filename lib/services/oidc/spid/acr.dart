// SPDX-License-Identifier: GPL-3.0-or-later

/// SPID/CIE Levels of Assurance (LoA).
///
/// CIE uses SpidL2 by AGID convention (no separate URI).
enum SpidLevel {
  l1('https://www.spid.gov.it/SpidL1'),
  l2('https://www.spid.gov.it/SpidL2'),
  l3('https://www.spid.gov.it/SpidL3');

  const SpidLevel(this.acrValue);
  final String acrValue;

  static SpidLevel? fromAcr(String? acr) {
    if (acr == null) return null;
    for (final l in SpidLevel.values) {
      if (l.acrValue == acr) return l;
    }
    return null;
  }
}
