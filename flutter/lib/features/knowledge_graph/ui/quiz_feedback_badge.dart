import 'package:flutter/material.dart';

import 'learn_pack_chrome.dart';
import 'learn_session_chrome.dart';

/// Correct/incorrect + explanation, shown below the session title row.
///
/// Dismissible; sits above the card so the quiz face height stays stable.
class QuizFeedbackBadge extends StatelessWidget {
  const QuizFeedbackBadge({
    super.key,
    required this.correct,
    required this.onDismiss,
    this.explanation,
    this.detail,
  });

  final bool correct;
  final String? explanation;
  final String? detail;
  final VoidCallback onDismiss;

  /// Top inset matching [LearnSessionCardStage] header bottom.
  static double topInset(BuildContext context) =>
      MediaQuery.paddingOf(context).top +
      LearnSessionCardStage.headerTop +
      LearnSessionCardStage.headerHeight +
      6;

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

    return Positioned(
      top: topInset(context),
      left: 20,
      right: 20,
      child: Material(
        color: Color.alphaBlend(
          accent.withValues(alpha: dark ? 0.28 : 0.16),
          scheme.surface,
        ),
        elevation: 3,
        shadowColor: Colors.black.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: accent,
                          ),
                    ),
                    if (body.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        body,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              height: 1.35,
                              color: scheme.onSurface.withValues(alpha: 0.82),
                            ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Dismiss',
                onPressed: onDismiss,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.close_rounded,
                  size: 20,
                  color: scheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
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
  final raw = body?['answer']?.toString().trim();
  if (raw == null || raw.isEmpty) return null;
  return raw;
}
