// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/theme/color_schemes.dart';
import '../../../models/enrolled_card.dart';
import '../../../models/enrolled_card_utils.dart';
import '../../../providers/settings_provider.dart';
import '../../../widgets/oc_card_avatar.dart';
import '../../../widgets/oc_section_label.dart';

/// The "Signer" box of the sign page: shows the selected card and, when two
/// or more cards are enrolled, lets the user pick another one (popup menu on
/// wide windows, bottom sheet on narrow ones). The choice is the shared
/// [AppSettings.selectedCard], so the CIE tab follows it too.
class SignerBox extends ConsumerWidget {
  const SignerBox({super.key, this.showLabel = true});

  /// Whether to render the "SIGNER" section label above the box.
  final bool showLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final settings = ref.watch(settingsProvider);
    final cards = settings.enrolledCards;
    final selected = settings.selectedCard;

    final Widget box;
    if (selected == null) {
      box = _boxShell(
        cs,
        Row(
          children: [
            Icon(Icons.credit_card_off_rounded, color: cs.error, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.signNoCardEnrolled,
                style: TextStyle(
                  fontFamily: 'Inter',
                  color: cs.error,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
    } else if (cards.length < 2) {
      box = _boxShell(cs, _SignerRow(card: selected));
    } else {
      final wide =
          MediaQuery.sizeOf(context).width >= AppConstants.mediumBreakpoint;
      final content = _boxShell(
        cs,
        _SignerRow(
          card: selected,
          trailing: Icon(
            Icons.unfold_more_rounded,
            size: 20,
            color: cs.onSurfaceVariant,
          ),
        ),
      );
      void select(String pan) =>
          ref.read(settingsProvider.notifier).selectCard(pan);
      box = wide
          ? PopupMenuButton<String>(
              key: const ValueKey('signerPicker'),
              tooltip: l10n.signSignerChangeTooltip,
              position: PopupMenuPosition.under,
              constraints: const BoxConstraints(minWidth: 280, maxWidth: 360),
              onSelected: select,
              itemBuilder: (_) => [
                for (final c in cards)
                  PopupMenuItem<String>(
                    key: ValueKey('signerOption_${c.pan}'),
                    value: c.pan,
                    child: _SignerRow(
                      card: c,
                      compact: true,
                      trailing: c.pan == selected.pan
                          ? Icon(Icons.check_rounded, color: cs.primary)
                          : null,
                    ),
                  ),
              ],
              child: content,
            )
          : Semantics(
              button: true,
              label: l10n.signSignerChangeTooltip,
              child: InkWell(
                key: const ValueKey('signerPicker'),
                borderRadius: BorderRadius.circular(14),
                onTap: () => _showSheet(context, cards, selected, select),
                child: content,
              ),
            );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showLabel) ...[
          OcSectionLabel(l10n.signSignerLabel),
          const SizedBox(height: 8),
        ],
        box,
        if (selected != null &&
            cardValidity(selected) == CardValidity.expired) ...[
          const SizedBox(height: 6),
          Row(
            key: const ValueKey('signerExpiredHint'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, size: 16, color: cs.invalid),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.cieErrorCardExpired,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    color: cs.invalid,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ],
        if (cards.length > 1) ...[
          const SizedBox(height: 6),
          Text(
            l10n.signSignerPresentHint,
            key: const ValueKey('signerPresentHint'),
            style: TextStyle(
              fontFamily: 'Inter',
              color: cs.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ],
      ],
    );
  }

  Widget _boxShell(ColorScheme cs, Widget child) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: cs.surfaceContainer,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: cs.outlineVariant),
    ),
    child: child,
  );

  Future<void> _showSheet(
    BuildContext context,
    List<EnrolledCard> cards,
    EnrolledCard selected,
    ValueChanged<String> onSelect,
  ) {
    final l10n = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  l10n.signSignerPickerTitle,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    color: cs.onSurface,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 12),
                  children: [
                    for (final c in cards)
                      InkWell(
                        key: ValueKey('signerOption_${c.pan}'),
                        onTap: () {
                          onSelect(c.pan);
                          Navigator.of(sheetContext).pop();
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          child: _SignerRow(
                            card: c,
                            trailing: c.pan == selected.pan
                                ? Icon(Icons.check_rounded, color: cs.primary)
                                : null,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SignerRow extends StatelessWidget {
  const _SignerRow({required this.card, this.trailing, this.compact = false});

  final EnrolledCard card;
  final Widget? trailing;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final id = cardFiscalCode(card) ?? card.serial;
    final expired = cardValidity(card) == CardValidity.expired;
    return Row(
      children: [
        OcCardAvatar(card: card, size: compact ? 32 : 36),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                card.displayName,
                key: const ValueKey('signerName'),
                style: TextStyle(
                  fontFamily: 'Inter',
                  color: cs.onSurface,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (id.isNotEmpty)
                OcMonoText(
                  id,
                  color: cs.onSurfaceVariant,
                  fontSize: 11,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              if (expired)
                Text(
                  AppLocalizations.of(context).cieCardStatusExpired,
                  key: const ValueKey('signerRowExpired'),
                  style: TextStyle(
                    fontFamily: 'Inter',
                    color: cs.invalid,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    );
  }
}
