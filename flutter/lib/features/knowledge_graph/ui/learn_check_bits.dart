import 'package:flutter/material.dart';

import '../models.dart';
import 'learn_pack_chrome.dart';

String checkTypeOf(TopicBit? bit) {
  final raw = bit?.body['type']?.toString().trim().toLowerCase();
  if (raw == 'true_false' || raw == 'cloze' || raw == 'mc') return raw!;
  if (bit?.body['choices'] is List) return 'mc';
  if (bit?.body.containsKey('statement') == true) return 'true_false';
  if (bit?.body.containsKey('prompt') == true) return 'cloze';
  return 'mc';
}

bool gradeCloze(TopicBit bit, String input) {
  final needle = input.trim().toLowerCase();
  if (needle.isEmpty) return false;
  final answer = bit.body['answer']?.toString().trim().toLowerCase() ?? '';
  if (answer.isNotEmpty && needle == answer) return true;
  final aliases = bit.body['aliases'];
  if (aliases is List) {
    for (final row in aliases) {
      if (row.toString().trim().toLowerCase() == needle) return true;
    }
  }
  return false;
}

class LearnCheckBit extends StatelessWidget {
  const LearnCheckBit({
    super.key,
    required this.bit,
    required this.selected,
    required this.revealed,
    required this.clozeController,
    required this.onSelectChoice,
    required this.onSelectBool,
    required this.onSubmitCloze,
  });

  final TopicBit? bit;
  final int selected;
  final bool revealed;
  final TextEditingController clozeController;
  final ValueChanged<int> onSelectChoice;
  final ValueChanged<bool> onSelectBool;
  final VoidCallback onSubmitCloze;

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
      'cloze' => _ClozeCheck(
          bit: bit!,
          revealed: revealed,
          controller: clozeController,
          onSubmit: onSubmitCloze,
        ),
      _ => _McCheck(
          bit: bit!,
          selected: selected,
          revealed: revealed,
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
  });

  final TopicBit bit;
  final int selected;
  final bool revealed;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final question = bit.body['question']?.toString() ?? '';
    final choicesRaw = bit.body['choices'];
    final choices = [
      if (choicesRaw is List)
        for (final row in choicesRaw) row.toString(),
    ];
    final answerIndex = (bit.body['answer_index'] as num?)?.toInt() ?? 0;
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
        for (var i = 0; i < choices.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _ChoiceTile(
            label: choices[i],
            selected: selected == i,
            revealed: revealed,
            correct: i == answerIndex,
            onTap: () => onSelect(i),
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

class _ClozeCheck extends StatelessWidget {
  const _ClozeCheck({
    required this.bit,
    required this.revealed,
    required this.controller,
    required this.onSubmit,
  });

  final TopicBit bit;
  final bool revealed;
  final TextEditingController controller;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final prompt = bit.body['prompt']?.toString() ??
        bit.body['question']?.toString() ??
        '';
    final correct = revealed && gradeCloze(bit, controller.text);
    final dark = scheme.brightness == Brightness.dark;
    final resultColor =
        correct ? learnOkColor(scheme.brightness) : learnBadColor(scheme.brightness);
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
        TextField(
          controller: controller,
          enabled: !revealed,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) {
            if (!revealed) onSubmit();
          },
          decoration: InputDecoration(
            hintText: 'Fill in the blank',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            enabledBorder: revealed
                ? OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: resultColor.withValues(alpha: 0.75)),
                  )
                : null,
            disabledBorder: revealed
                ? OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: resultColor.withValues(alpha: 0.75)),
                  )
                : null,
            filled: revealed,
            fillColor: revealed ? resultColor.withValues(alpha: dark ? 0.22 : 0.12) : null,
          ),
        ),
        const SizedBox(height: 10),
        // Keep Check row height so reveal doesn't resize the card.
        // Disable (don't remove) so the Check tap can't retarget onto Next/Done.
        Align(
          alignment: Alignment.centerRight,
          child: Opacity(
            opacity: revealed ? 0 : 1,
            child: IgnorePointer(
              ignoring: revealed,
              child: FilledButton(
                onPressed: revealed ? null : onSubmit,
                child: const Text('Check'),
              ),
            ),
          ),
        ),
      ],
    );
  }
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
