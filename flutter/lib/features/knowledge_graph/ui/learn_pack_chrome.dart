import 'package:flutter/material.dart';

import '../../../core/widgets/pulse_placeholder.dart';
import '../models.dart';

Color learnOkColor(Brightness brightness) =>
    brightness == Brightness.dark ? const Color(0xFF81C784) : const Color(0xFF2E7D32);

Color learnBadColor(Brightness brightness) =>
    brightness == Brightness.dark ? const Color(0xFFE57373) : const Color(0xFFC62828);

class LearnPackBadgeRow extends StatelessWidget {
  const LearnPackBadgeRow({
    super.key,
    required this.packs,
    required this.selectedPackIndex,
    required this.completedPackIndexes,
    required this.canGenerateAnother,
    required this.generatingAnother,
    required this.onSelectPack,
    required this.onGenerateAnother,
  });

  final List<TopicPack> packs;
  final int selectedPackIndex;
  final Set<int> completedPackIndexes;
  final bool canGenerateAnother;
  final bool generatingAnother;
  final ValueChanged<int> onSelectPack;
  final VoidCallback? onGenerateAnother;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final pack in packs) ...[
            _PackBadge(
              label: pack.badgeLabel,
              selected: pack.packIndex == selectedPackIndex,
              incomplete: pack.incomplete,
              completed: completedPackIndexes.contains(pack.packIndex),
              onTap: () => onSelectPack(pack.packIndex),
            ),
            const SizedBox(width: 8),
          ],
          _GenerateAnotherChip(
            enabled: canGenerateAnother,
            busy: generatingAnother,
            onTap: onGenerateAnother,
          ),
        ],
      ),
    );
  }
}

class LearnStepDots extends StatelessWidget {
  const LearnStepDots({super.key, required this.step, required this.total});

  final int step;
  final int total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (var i = 0; i < total; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            width: i == step ? 22 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: i == step
                  ? scheme.primary
                  : scheme.onSurface.withValues(alpha: i < step ? 0.35 : 0.16),
              borderRadius: BorderRadius.circular(99),
            ),
          ),
        ],
      ],
    );
  }
}

class LearnBitSection extends StatelessWidget {
  const LearnBitSection({
    super.key,
    required this.label,
    required this.loading,
    required this.child,
  });

  final String label;
  final bool loading;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.onSurface.withValues(
        alpha: scheme.brightness == Brightness.dark ? 0.10 : 0.045,
      ),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: scheme.onSurface.withValues(alpha: 0.72),
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 10),
            if (loading)
              const SizedBox(
                height: 110,
                child: PulsePlaceholder(
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                ),
              )
            else
              child,
          ],
        ),
      ),
    );
  }
}

class LearnMarkdownBit extends StatelessWidget {
  const LearnMarkdownBit({super.key, this.bit});

  final TopicBit? bit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (bit == null) {
      return Text(
        'No content yet.',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.45),
              fontStyle: FontStyle.italic,
            ),
      );
    }
    final title = bit!.body['title']?.toString().trim();
    final markdown = bit!.body['markdown']?.toString().trim() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null && title.isNotEmpty) ...[
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
        ],
        Text(
          plainMarkdown(markdown),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                height: 1.45,
                color: scheme.onSurface.withValues(alpha: 0.88),
              ),
        ),
      ],
    );
  }
}

String plainMarkdown(String raw) {
  return raw
      .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m.group(1) ?? '')
      .replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m.group(1) ?? '')
      .replaceAll(RegExp(r'^#+\s*', multiLine: true), '')
      .trim();
}

class _PackBadge extends StatelessWidget {
  const _PackBadge({
    required this.label,
    required this.selected,
    required this.incomplete,
    required this.completed,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool incomplete;
  final bool completed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final ok = learnOkColor(scheme.brightness);
    Color fill = scheme.onSurface.withValues(alpha: 0.06);
    Color border = scheme.onSurface.withValues(alpha: 0.12);
    Color labelColor = scheme.onSurface.withValues(alpha: selected ? 0.92 : 0.7);
    if (completed) {
      fill = ok.withValues(alpha: dark ? 0.22 : 0.14);
      border = ok.withValues(alpha: selected ? 0.9 : 0.75);
      labelColor = ok;
    } else if (selected) {
      fill = scheme.primary.withValues(alpha: 0.16);
      border = scheme.primary.withValues(alpha: 0.45);
    }
    return Material(
      color: fill,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: border),
          ),
          child: Text(
            incomplete ? '$label…' : label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: labelColor,
                ),
          ),
        ),
      ),
    );
  }
}

class _GenerateAnotherChip extends StatelessWidget {
  const _GenerateAnotherChip({
    required this.enabled,
    required this.busy,
    required this.onTap,
  });

  final bool enabled;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.onSurface.withValues(alpha: enabled ? 0.08 : 0.04),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: scheme.onSurface.withValues(alpha: 0.12)),
          ),
          child: Text(
            busy ? 'Generating…' : 'Generate another',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface.withValues(alpha: enabled || busy ? 0.8 : 0.35),
                ),
          ),
        ),
      ),
    );
  }
}
