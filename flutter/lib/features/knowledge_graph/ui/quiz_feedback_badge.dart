import 'package:flutter/material.dart';

import '../models.dart';
import 'learn_check_bits.dart';
import 'learn_pack_chrome.dart';

/// Correct/incorrect + explanation, pinned to the bottom of the quiz image.
class QuizFeedbackBadge extends StatelessWidget {
  const QuizFeedbackBadge({
    super.key,
    required this.correct,
    this.explanation,
    this.detail,
  });

  final bool correct;
  final String? explanation;
  final String? detail;

  factory QuizFeedbackBadge.fromBit({
    Key? key,
    required TopicBit? bit,
    required bool correct,
  }) {
    final body = bit?.body;
    final type = checkTypeOf(bit);
    String? detail;
    if (!correct && (type == 'cloze' || type == 'mc')) {
      final expected = quizExpectedAnswerOf(body);
      if (expected != null) detail = 'Answer: $expected';
    }
    return QuizFeedbackBadge(
      key: key,
      correct: correct,
      explanation: quizExplanationOf(body),
      detail: detail,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final accent =
        correct ? learnOkColor(scheme.brightness) : learnBadColor(scheme.brightness);
    final title = correct ? 'Correct' : 'Incorrect';
    final body = [
      if (detail != null && detail!.trim().isNotEmpty) detail!.trim(),
      if (explanation != null && explanation!.trim().isNotEmpty)
        explanation!.trim(),
    ].join('\n');

    return Material(
      color: Color.alphaBlend(
        accent.withValues(alpha: dark ? 0.42 : 0.92),
        scheme.surface.withValues(alpha: dark ? 0.92 : 0.96),
      ),
      elevation: 2,
      shadowColor: Colors.black.withValues(alpha: 0.28),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: accent,
                  ),
            ),
            if (body.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                body,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      height: 1.3,
                      color: scheme.onSurface.withValues(alpha: 0.88),
                    ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String? quizExplanationOf(Map<String, dynamic>? body) {
  final raw = body?['explanation']?.toString().trim();
  if (raw == null || raw.isEmpty) return null;
  return raw;
}

String? quizExpectedAnswerOf(Map<String, dynamic>? body) {
  if (body == null) return null;
  final choices = body['choices'];
  final index = (body['answer_index'] as num?)?.toInt();
  if (choices is List && index != null && index >= 0 && index < choices.length) {
    final pick = choices[index].toString().trim();
    if (pick.isNotEmpty) return pick;
  }
  final raw = body['answer']?.toString().trim();
  if (raw == null || raw.isEmpty) return null;
  return raw;
}
