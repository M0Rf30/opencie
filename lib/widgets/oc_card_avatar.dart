// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../core/theme/color_schemes.dart';
import '../models/enrolled_card.dart';
import '../models/enrolled_card_utils.dart';

/// Round gradient avatar carrying the holder's initials. Shared by the CIE
/// card list and the signer picker so a card looks the same everywhere.
class OcCardAvatar extends StatelessWidget {
  const OcCardAvatar({super.key, required this.card, this.size = 36});

  final EnrolledCard card;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: ColorSchemes.chipGradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        cardInitials(card),
        style: TextStyle(
          fontFamily: 'Inter',
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.38,
        ),
      ),
    );
  }
}
