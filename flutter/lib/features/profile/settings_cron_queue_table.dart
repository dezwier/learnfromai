import 'package:flutter/material.dart';

String cronFmtScore(double value) {
  if (value == 0) return '0';
  if (value >= 10) return value.toStringAsFixed(1);
  final two = value.toStringAsFixed(2);
  if (two.endsWith('00')) return value.toStringAsFixed(0);
  if (two.endsWith('0')) return value.toStringAsFixed(1);
  return two;
}

class CronQueueTable extends StatelessWidget {
  const CronQueueTable({
    super.key,
    required this.title,
    required this.subtitle,
    required this.columns,
    required this.flex,
    required this.rows,
    this.trailing,
    this.weightLabel,
    this.weight,
    this.onWeightChanged,
    this.weightEnabled = true,
  });

  final String title;
  final String subtitle;
  final List<String> columns;
  final List<int> flex;
  final List<List<String>> rows;
  final Widget? trailing;
  final String? weightLabel;
  final double? weight;
  final ValueChanged<double>? onWeightChanged;
  final bool weightEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ink = scheme.onSurface;
    final mute = ink.withValues(alpha: 0.48);
    final line = ink.withValues(alpha: 0.08);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                subtitle,
                style: theme.textTheme.labelSmall?.copyWith(color: mute),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing!,
            ],
          ],
        ),
        if (weight != null) ...[
          const SizedBox(height: 4),
          _FillWeightControl(
            label: weightLabel ?? 'Weight',
            value: weight!,
            onChanged: weightEnabled ? onWeightChanged : null,
          ),
        ],
        const SizedBox(height: 8),
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: line),
            color: scheme.surface.withValues(alpha: 0.55),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                child: _TableRow(
                  cells: columns,
                  flex: flex,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: mute,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              Divider(height: 1, thickness: 1, color: line),
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'None',
                      style: theme.textTheme.bodySmall?.copyWith(color: mute),
                    ),
                  ),
                )
              else
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) Divider(height: 1, thickness: 1, color: line),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    child: _TableRow(
                      cells: rows[i],
                      flex: flex,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: ink.withValues(alpha: 0.88),
                        height: 1.2,
                      ),
                      emphasisIndex: 4,
                      mutedIndex: 5,
                    ),
                  ),
                ],
            ],
          ),
        ),
      ],
    );
  }
}

class _FillWeightControl extends StatelessWidget {
  const _FillWeightControl({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double>? onChanged;

  static const _step = 0.1;
  static const _max = 50.0;

  double _round(double v) => (v * 10).roundToDouble() / 10;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mute = theme.colorScheme.onSurface.withValues(alpha: 0.55);
    final enabled = onChanged != null;
    final display = value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : cronFmtScore(value);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(color: mute),
        ),
        IconButton(
          tooltip: 'Decrease',
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          onPressed: enabled && value > 0
              ? () => onChanged!(_round((value - _step).clamp(0, _max)))
              : null,
          icon: const Icon(Icons.remove, size: 16),
        ),
        SizedBox(
          width: 36,
          child: Text(
            display,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        IconButton(
          tooltip: 'Increase',
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          onPressed: enabled && value < _max
              ? () => onChanged!(_round((value + _step).clamp(0, _max)))
              : null,
          icon: const Icon(Icons.add, size: 16),
        ),
      ],
    );
  }
}

class _TableRow extends StatelessWidget {
  const _TableRow({
    required this.cells,
    required this.flex,
    required this.style,
    this.emphasisIndex,
    this.mutedIndex,
  });

  final List<String> cells;
  final List<int> flex;
  final TextStyle? style;
  final int? emphasisIndex;
  final int? mutedIndex;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < cells.length; i++)
          Expanded(
            flex: flex[i],
            child: Text(
              cells[i],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: i == 0 ? TextAlign.left : TextAlign.right,
              style: style?.copyWith(
                fontWeight: i == emphasisIndex ? FontWeight.w700 : style?.fontWeight,
                color: i == mutedIndex
                    ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.45)
                    : style?.color,
              ),
            ),
          ),
      ],
    );
  }
}
