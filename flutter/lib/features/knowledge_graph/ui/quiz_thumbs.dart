import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Compact thumbs up / down for quiz quality feedback.
class QuizThumbs extends StatelessWidget {
  const QuizThumbs({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  /// `1` up, `-1` down, `null` unset.
  final int? value;
  final ValueChanged<int> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ThumbButton(
          icon: Icons.thumb_up_alt_rounded,
          selected: value == 1,
          selectedColor: const Color(0xFF2E9B63),
          enabled: enabled,
          semanticLabel: 'Thumbs up',
          onTap: () {
            HapticFeedback.selectionClick();
            onChanged(1);
          },
        ),
        const SizedBox(width: 6),
        _ThumbButton(
          icon: Icons.thumb_down_alt_rounded,
          selected: value == -1,
          selectedColor: scheme.error,
          enabled: enabled,
          semanticLabel: 'Thumbs down',
          onTap: () {
            HapticFeedback.selectionClick();
            onChanged(-1);
          },
        ),
      ],
    );
  }
}

class _ThumbButton extends StatelessWidget {
  const _ThumbButton({
    required this.icon,
    required this.selected,
    required this.selectedColor,
    required this.enabled,
    required this.semanticLabel,
    required this.onTap,
  });

  final IconData icon;
  final bool selected;
  final Color selectedColor;
  final bool enabled;
  final String semanticLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = selected
        ? selectedColor.withValues(alpha: 0.18)
        : scheme.surface.withValues(alpha: 0.92);
    final fg = selected
        ? selectedColor
        : scheme.onSurface.withValues(alpha: enabled ? 0.72 : 0.35);
    final border = selected
        ? selectedColor.withValues(alpha: 0.45)
        : scheme.outline.withValues(alpha: 0.22);

    return Semantics(
      button: true,
      label: semanticLabel,
      selected: selected,
      child: Material(
        color: bg,
        elevation: selected ? 2 : 1,
        shadowColor: Colors.black.withValues(alpha: 0.22),
        shape: CircleBorder(side: BorderSide(color: border)),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onTap : null,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(icon, size: 22, color: fg),
          ),
        ),
      ),
    );
  }
}
