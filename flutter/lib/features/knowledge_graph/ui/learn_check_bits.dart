import 'package:flutter/material.dart';

import '../models.dart';
import 'learn_pack_chrome.dart';

String checkTypeOf(TopicBit? bit) {
  final raw = bit?.body['type']?.toString().trim().toLowerCase();
  if (raw == 'true_false' || raw == 'cloze' || raw == 'mc') return raw!;
  if (bit?.body['choices'] is List && bit?.body.containsKey('prompt') == true) {
    return 'cloze';
  }
  if (bit?.body['choices'] is List) return 'mc';
  if (bit?.body.containsKey('statement') == true) return 'true_false';
  if (bit?.body.containsKey('prompt') == true) return 'cloze';
  return 'mc';
}

/// Shuffled original indices for MC/cloze, or null for true/false / no choices.
List<int>? choiceOrderForBit(TopicBit? bit) {
  if (bit == null) return null;
  if (checkTypeOf(bit) == 'true_false') return null;
  final choices = _readChoices(bit);
  if (choices.length < 2) return null;
  return _shuffledOrder(choices.length);
}

class LearnCheckBit extends StatelessWidget {
  const LearnCheckBit({
    super.key,
    required this.bit,
    required this.selected,
    required this.revealed,
    required this.onSelectChoice,
    required this.onSelectBool,
    this.choiceOrder,
  });

  final TopicBit? bit;
  final int selected;
  final bool revealed;
  final ValueChanged<int> onSelectChoice;
  final ValueChanged<bool> onSelectBool;
  /// Display order of original choice indexes; owned by the card so reveal
  /// rebuilds do not reshuffle.
  final List<int>? choiceOrder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (bit == null) {
      return Text(
        'No check yet.',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.45),
              fontStyle: FontStyle.italic,
            ),
      );
    }
    final type = checkTypeOf(bit);
    return switch (type) {
      'true_false' => _TrueFalseCheck(
          bit: bit!,
          selected: selected,
          revealed: revealed,
          onSelect: onSelectBool,
        ),
      'cloze' => _ClozeMcCheck(
          bit: bit!,
          selected: selected,
          revealed: revealed,
          order: choiceOrder,
          onSelect: onSelectChoice,
        ),
      _ => _McCheck(
          bit: bit!,
          selected: selected,
          revealed: revealed,
          order: choiceOrder,
          onSelect: onSelectChoice,
        ),
    };
  }
}

class _McCheck extends StatelessWidget {
  const _McCheck({
    required this.bit,
    required this.selected,
    required this.revealed,
    required this.onSelect,
    this.order,
  });

  final TopicBit bit;
  final int selected;
  final bool revealed;
  final ValueChanged<int> onSelect;
  final List<int>? order;

  @override
  Widget build(BuildContext context) {
    final question = bit.body['question']?.toString() ?? '';
    final choices = _readChoices(bit);
    final answerIndex = (bit.body['answer_index'] as num?)?.toInt() ?? 0;
    final displayOrder = _effectiveOrder(order, choices.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          question,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                height: 1.3,
              ),
        ),
        const SizedBox(height: 12),
        for (var display = 0; display < displayOrder.length; display++) ...[
          if (display > 0) const SizedBox(height: 8),
          _ChoiceTile(
            label: choices[displayOrder[display]],
            selected: selected == displayOrder[display],
            revealed: revealed,
            correct: displayOrder[display] == answerIndex,
            onTap: () => onSelect(displayOrder[display]),
          ),
        ],
      ],
    );
  }
}

class _TrueFalseCheck extends StatelessWidget {
  const _TrueFalseCheck({
    required this.bit,
    required this.selected,
    required this.revealed,
    required this.onSelect,
  });

  final TopicBit bit;
  final int selected;
  final bool revealed;
  final ValueChanged<bool> onSelect;

  @override
  Widget build(BuildContext context) {
    final statement = bit.body['statement']?.toString() ??
        bit.body['question']?.toString() ??
        '';
    final answer = bit.body['answer'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          statement,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                height: 1.3,
              ),
        ),
        const SizedBox(height: 12),
        _ChoiceTile(
          label: 'True',
          selected: selected == 1,
          revealed: revealed,
          correct: answer,
          onTap: () => onSelect(true),
        ),
        const SizedBox(height: 8),
        _ChoiceTile(
          label: 'False',
          selected: selected == 0,
          revealed: revealed,
          correct: !answer,
          onTap: () => onSelect(false),
        ),
      ],
    );
  }
}

/// Cloze = blank in a prompt + one-word multiple choice (not free text).
class _ClozeMcCheck extends StatelessWidget {
  const _ClozeMcCheck({
    required this.bit,
    required this.selected,
    required this.revealed,
    required this.onSelect,
    this.order,
  });

  final TopicBit bit;
  final int selected;
  final bool revealed;
  final ValueChanged<int> onSelect;
  final List<int>? order;

  @override
  Widget build(BuildContext context) {
    final prompt = bit.body['prompt']?.toString() ??
        bit.body['question']?.toString() ??
        '';
    final choices = _readChoices(bit);
    final answerIndex = (bit.body['answer_index'] as num?)?.toInt() ?? 0;
    if (choices.length < 2) {
      return const SizedBox.shrink();
    }
    final displayOrder = _effectiveOrder(order, choices.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          prompt,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                height: 1.3,
              ),
        ),
        const SizedBox(height: 12),
        for (var display = 0; display < displayOrder.length; display++) ...[
          if (display > 0) const SizedBox(height: 8),
          _ChoiceTile(
            label: choices[displayOrder[display]],
            selected: selected == displayOrder[display],
            revealed: revealed,
            correct: displayOrder[display] == answerIndex,
            onTap: () => onSelect(displayOrder[display]),
          ),
        ],
      ],
    );
  }
}

List<String> _readChoices(TopicBit bit) {
  final choicesRaw = bit.body['choices'];
  return [
    if (choicesRaw is List)
      for (final row in choicesRaw) row.toString(),
  ];
}

List<int> _shuffledOrder(int length) {
  final order = List<int>.generate(length, (i) => i);
  order.shuffle();
  return order;
}

List<int> _effectiveOrder(List<int>? order, int length) {
  if (order != null &&
      order.length == length &&
      order.toSet().length == length &&
      order.every((i) => i >= 0 && i < length)) {
    return order;
  }
  return List<int>.generate(length, (i) => i);
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.label,
    required this.selected,
    required this.revealed,
    required this.correct,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool revealed;
  final bool correct;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final ok = learnOkColor(scheme.brightness);
    final bad = learnBadColor(scheme.brightness);
    Color border = scheme.onSurface.withValues(alpha: 0.12);
    Color fill = Colors.transparent;
    Color? labelColor;
    if (revealed && correct) {
      border = ok.withValues(alpha: 0.75);
      fill = ok.withValues(alpha: dark ? 0.22 : 0.14);
      labelColor = ok;
    } else if (revealed && selected && !correct) {
      border = bad.withValues(alpha: 0.75);
      fill = bad.withValues(alpha: dark ? 0.22 : 0.12);
      labelColor = bad;
    } else if (selected) {
      border = scheme.primary.withValues(alpha: 0.4);
      fill = scheme.primary.withValues(alpha: 0.06);
    }
    return Material(
      color: fill,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: revealed ? null : onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: border),
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  height: 1.35,
                  color: labelColor,
                  fontWeight: labelColor != null ? FontWeight.w600 : null,
                ),
          ),
        ),
      ),
    );
  }
}
