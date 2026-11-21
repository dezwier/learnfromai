import 'package:flutter/material.dart';

import '../../profile/overlay_panel_chrome.dart';

/// Floating bottom CTA with no fade bar — card shows behind it.
///
/// Must be a direct [Stack] child ([Positioned] root).
class LearnSessionFloatingCta extends StatelessWidget {
  const LearnSessionFloatingCta({
    super.key,
    required this.label,
    required this.onPressed,
    this.visible = true,
  });

  final String label;
  final VoidCallback? onPressed;
  /// When false, keeps layout space but fades out and ignores taps.
  final bool visible;

  /// Space to keep clear above the home indicator / keyboard for the CTA.
  ///
  /// Pass [reserveCta]: true whenever a Next/Done slot should stay reserved
  /// (even before the button is visible) so the card never jumps.
  /// Matches [TurnableYAxisCard] corner radius.
  static const double radius = 16;

  static double clearance(BuildContext context, {bool reserveCta = true}) {
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    // While typing (cloze), lift only just above the keyboard — don't also
    // reserve the Next/Done slot or the field jumps too high.
    if (keyboard > 0.5) {
      return keyboard + 12;
    }
    if (!reserveCta) {
      return media.padding.bottom + 24;
    }
    // Button (52) + bottom inset (16) + gap above button (20).
    return media.padding.bottom + 88;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Positioned(
      left: 20,
      right: 20,
      bottom: media.padding.bottom + media.viewInsets.bottom + 16,
      // Absorb (don't ignore) while hidden so leftover keyboard/Check taps
      // can't fall through to whatever sits under this slot.
      child: AbsorbPointer(
        absorbing: !visible || onPressed == null,
        child: AnimatedOpacity(
          opacity: visible && onPressed != null ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: FilledButton(
            onPressed: onPressed,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              elevation: 4,
              shadowColor: Colors.black.withValues(alpha: 0.28),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(radius),
              ),
              textStyle: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            child: Text(label),
          ),
        ),
      ),
    );
  }
}

/// Transparent top chrome (title + optional meta + close) behind the card stage.
///
/// The card is laid out below the header; Y-flip overflow paints in front of it.
class LearnSessionCardStage extends StatelessWidget {
  const LearnSessionCardStage({
    super.key,
    required this.title,
    required this.onClose,
    required this.card,
    required this.bottomClearance,
    this.meta,
    this.titleColor,
    this.titleShadows,
    this.metaColor,
  });

  final String title;
  final String? meta;
  final VoidCallback onClose;
  final Widget card;
  final double bottomClearance;
  final Color? titleColor;
  final List<Shadow>? titleShadows;
  final Color? metaColor;

  static double get headerTop => OverlayPanel.closeInset;
  static double get headerHeight => OverlayPanel.closeSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final resolvedTitleColor = titleColor ?? scheme.onSurface;
    final resolvedMetaColor =
        metaColor ?? scheme.onSurface.withValues(alpha: 0.55);

    return Stack(
      clipBehavior: Clip.none,
      fit: StackFit.expand,
      children: [
        Positioned(
          top: headerTop,
          left: 16,
          right: OverlayPanel.closeInset + 2,
          height: headerHeight,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: resolvedTitleColor,
                        shadows: titleShadows,
                      ),
                ),
              ),
              if (meta != null && meta!.trim().isNotEmpty) ...[
                const SizedBox(width: 10),
                Text(
                  meta!,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: resolvedMetaColor,
                        fontWeight: FontWeight.w600,
                        shadows: titleShadows,
                      ),
                ),
              ],
              const SizedBox(width: 10),
              OverlayCloseButton(onPressed: onClose),
            ],
          ),
        ),
        Positioned(
          top: headerTop + headerHeight + 4,
          left: 20,
          right: 20,
          bottom: bottomClearance,
          // Bounded height so the card can shrink its image to fit.
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxHeight <= 0) {
                return const SizedBox.shrink();
              }
              return card;
            },
          ),
        ),
      ],
    );
  }
}
