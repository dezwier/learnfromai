import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/pulse_placeholder.dart';
import '../../core/widgets/study_card.dart';
import 'review_controller.dart';

class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  final _answer = TextEditingController();

  @override
  void dispose() {
    _answer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final review = context.watch<ReviewController>();
    if (review.loading && review.due.isEmpty) {
      return const Padding(padding: studyPagePadding, child: SizedBox(height: 240, child: PulsePlaceholder()));
    }
    if (review.due.isEmpty) {
      return ListView(
        padding: studyPagePadding,
        children: const [
          StudyCard(
            eyebrow: 'REVIEW',
            tint: Color(0xFF2E7D4F),
            title: 'Nothing due',
            subtitle: 'Nothing due. Reviews show up after you answer a question.',
          ),
        ],
      );
    }
    final item = review.due.first;
    return ListView(
      padding: studyPagePadding,
      children: [
        StudyCard(
          eyebrow: item['status'] == 'overdue' ? 'OVERDUE' : 'DUE',
          tint: const Color(0xFF8A5A00),
          title: item['prompt']?.toString() ?? 'Recall the idea',
          subtitle: 'Answer before you reveal',
          footer: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _answer,
                decoration: const InputDecoration(labelText: 'Your answer', filled: true, fillColor: Color(0xFFFFFCF7)),
                maxLines: 3,
              ),
              const SizedBox(height: 12),
              FilledButton(onPressed: () => review.submit(item['id'].toString(), _answer.text), child: const Text('Check')),
              TextButton(onPressed: review.reveal, child: const Text('Reveal')),
            ],
          ),
        ),
        if (review.revealed || review.feedback != null) ...[
          const SizedBox(height: 12),
          StudyCard(
            eyebrow: 'RESULT',
            tint: const Color(0xFF2E7D4F),
            title: 'Score ${review.feedback?['feedback']?['score'] ?? 'recorded'}',
          ),
        ],
        if (review.error != null) ...[const SizedBox(height: 12), Text(review.error!)],
      ],
    );
  }
}
