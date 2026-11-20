import 'package:flutter/material.dart';

import '../../profile/overlay_panel_chrome.dart';

/// Floating bottom CTA with no fade bar — card shows behind it.
class LearnSessionFloatingCta extends StatelessWidget {
  const LearnSessionFloatingCta({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  static double clearance(BuildContext context, {required bool visible}) {
    if (!visible) {
      return MediaQuery.paddingOf(context).bottom + 24;
    }
    return MediaQuery.paddingOf(context).bottom +
        MediaQuery.viewInsetsOf(context).bottom +
        72;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Positioned(
      left: 20,
      right: 20,
      bottom: media.padding.bottom + media.viewInsets.bottom + 16,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          elevation: 4,
          shadowColor: Colors.black.withValues(alpha: 0.28),
          textStyle: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        child: Text(label),
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
          child: SingleChildScrollView(
            clipBehavior: Clip.none,
            child: card,
          ),
        ),
      ],
    );
  }
}
