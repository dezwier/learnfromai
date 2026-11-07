import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/pulse_placeholder.dart';
import '../../core/widgets/study_card.dart';
import '../goals/goals_controller.dart';
import 'learn_controller.dart';

class LearnScreen extends StatefulWidget {
  const LearnScreen({super.key});

  @override
  State<LearnScreen> createState() => _LearnScreenState();
}

class _LearnScreenState extends State<LearnScreen> {
  final _answer = TextEditingController();

  @override
  void dispose() {
    _answer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final learn = context.watch<LearnController>();
    final goals = context.watch<GoalsController>();
    if (learn.loading && learn.activity == null) {
      return const Padding(padding: studyPagePadding, child: SizedBox(height: 280, child: PulsePlaceholder()));
    }
    final body = learn.activity?['body'] as Map?;
    final prompt = body?['explanation']?.toString() ?? body?['prompt']?.toString() ?? 'Activity';
    return ListView(
      padding: studyPagePadding,
      children: [
        if (learn.activity == null)
          StudyCard(
            eyebrow: 'LEARN',
            title: 'Start the next step',
            subtitle: 'Read first. Answering is what counts toward mastery.',
            footer: FilledButton(
              onPressed: goals.goal == null ? null : () => learn.start(goals.goal!['id'].toString()),
              child: const Text('Start the next step'),
            ),
          )
        else
          StudyCard(
            eyebrow: 'CARD',
            title: prompt,
            subtitle: body?['worked_example']?.toString(),
            footer: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _answer,
                  decoration: const InputDecoration(labelText: 'Your answer', filled: true, fillColor: Color(0xFFFFFCF7)),
                  maxLines: 4,
                ),
                const SizedBox(height: 12),
                FilledButton(onPressed: () => learn.submit(_answer.text), child: const Text('Submit')),
              ],
            ),
          ),
        if (learn.feedback != null) ...[
          const SizedBox(height: 12),
          StudyCard(
            eyebrow: 'FEEDBACK',
            tint: const Color(0xFF2E7D4F),
            title: 'Score ${learn.feedback!['feedback']?['score'] ?? '—'}',
            subtitle: [
              learn.feedback!['feedback']?['next_hint']?.toString() ?? '',
              if (learn.feedback!['feedback']?['uncertain'] == true) 'Grading is uncertain. Try another question.',
            ].where((line) => line.isNotEmpty).join('\n'),
          ),
        ],
        if (learn.error != null) ...[const SizedBox(height: 12), Text(learn.error!)],
      ],
    );
  }
}
