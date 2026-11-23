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
  });

  final String title;
  final String subtitle;
  final List<String> columns;
  final List<int> flex;
  final List<List<String>> rows;
  final Widget? trailing;

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
