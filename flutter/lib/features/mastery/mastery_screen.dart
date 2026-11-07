import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/pulse_placeholder.dart';
import '../../core/widgets/study_card.dart';
import '../goals/goals_controller.dart';
import 'mastery_controller.dart';

class MasteryScreen extends StatelessWidget {
  const MasteryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final mastery = context.watch<MasteryController>();
    final goals = context.watch<GoalsController>();
    if (mastery.loading && mastery.overview == null) {
      return const Padding(padding: studyPagePadding, child: SizedBox(height: 240, child: PulsePlaceholder()));
    }
    final concepts = (mastery.overview?['concepts'] as List?) ?? [];
    return ListView(
      padding: studyPagePadding,
      children: [
        if (concepts.isEmpty && goals.goal != null)
          const StudyCard(eyebrow: 'EMPTY', title: 'No assessed objectives yet', subtitle: 'Answer a question and a card will appear here.')
        else
          for (final raw in concepts) ...[
            _ConceptCard(concept: Map<String, dynamic>.from(raw as Map)),
            const SizedBox(height: 12),
          ],
        if (mastery.changes.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Graph updates', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final change in mastery.changes) ...[
            StudyCard(
              dense: true,
              eyebrow: 'CHANGE',
              title: change['status']?.toString() ?? '',
              subtitle: '${change['from_release_id']} → ${change['to_release_id']}',
            ),
            const SizedBox(height: 12),
          ],
        ],
        const SizedBox(height: 4),
        Text(
          'These are evidence summaries, not a guarantee of skill.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
        ),
        if (mastery.error != null) Text(mastery.error!),
      ],
    );
  }
}

class _ConceptCard extends StatelessWidget {
  const _ConceptCard({required this.concept});

  final Map<String, dynamic> concept;

  @override
  Widget build(BuildContext context) {
    final status = concept['status']?.toString() ?? 'unknown';
    return StudyCard(
      tint: masteryColor(status),
      eyebrow: masteryLabel(status).toUpperCase(),
      title: concept['title']?.toString() ?? '',
      subtitle: 'estimate ${concept['estimate'] ?? 0} · confidence ${concept['confidence'] ?? 0}',
    );
  }
}
