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
  /// Pass `null` to clear the previous rating.
  final ValueChanged<int?> onChanged;
  final bool enabled;

  void _tap(int rating) {
    HapticFeedback.selectionClick();
    onChanged(value == rating ? null : rating);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final idle = scheme.onSurface.withValues(alpha: enabled ? 0.42 : 0.22);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ThumbButton(
          icon: value == 1 ? Icons.thumb_up_alt_rounded : Icons.thumb_up_alt_outlined,
          selected: value == 1,
          color: value == 1 ? const Color(0xFF2E9B63) : idle,
          enabled: enabled,
          semanticLabel: 'Thumbs up',
          onTap: () => _tap(1),
        ),
        const SizedBox(width: 2),
        _ThumbButton(
          icon: value == -1 ? Icons.thumb_down_alt_rounded : Icons.thumb_down_alt_outlined,
          selected: value == -1,
          color: value == -1 ? scheme.error.withValues(alpha: 0.85) : idle,
          enabled: enabled,
          semanticLabel: 'Thumbs down',
          onTap: () => _tap(-1),
        ),
      ],
    );
  }
}

class _ThumbButton extends StatelessWidget {
  const _ThumbButton({
    required this.icon,
    required this.selected,
    required this.color,
    required this.enabled,
    required this.semanticLabel,
    required this.onTap,
  });

  final IconData icon;
  final bool selected;
  final Color color;
  final bool enabled;
  final String semanticLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      selected: selected,
      child: IconButton(
        onPressed: enabled ? onTap : null,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 44),
        splashRadius: 18,
        icon: Icon(icon, size: 18, color: color),
      ),
    );
  }
}
