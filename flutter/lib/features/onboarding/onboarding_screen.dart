import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/gradient_top_bar.dart';
import '../../core/widgets/pulse_placeholder.dart';
import '../../core/widgets/study_card.dart';
import '../goals/goals_controller.dart';
import '../knowledge_graph/graph_controller.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _topic = TextEditingController();
  final _purpose = TextEditingController();
  String _depth = 'professional';
  double _minutes = 180;

  @override
  void dispose() {
    _topic.dispose();
    _purpose.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final goals = context.watch<GoalsController>();
    return Scaffold(
      appBar: GradientTopBar(
        title: 'New goal',
        leading: IconButton(
          tooltip: 'Back',
          onPressed: () => context.go('/graph'),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: ListView(
        padding: studyPagePadding,
        children: [
          StudyCard(
            eyebrow: 'NEW PATH',
            title: 'What should the first map cover?',
            subtitle: 'Name the topic. The path is added to the shared graph, then you can start learning.',
          ),
          const SizedBox(height: 16),
          TextField(controller: _topic, decoration: const InputDecoration(labelText: 'I want to master', filled: true)),
          const SizedBox(height: 12),
          TextField(controller: _purpose, decoration: const InputDecoration(labelText: 'Purpose')),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _depth,
            decoration: const InputDecoration(labelText: 'Depth'),
            items: const [
              DropdownMenuItem(value: 'overview', child: Text('Overview')),
              DropdownMenuItem(value: 'professional', child: Text('Professional')),
            ],
            onChanged: (value) => setState(() => _depth = value ?? 'professional'),
          ),
          const SizedBox(height: 12),
          Text('Weekly minutes: ${_minutes.round()}'),
          Slider(value: _minutes, min: 30, max: 600, divisions: 19, onChanged: (value) => setState(() => _minutes = value)),
          const SizedBox(height: 16),
          if (goals.loading)
            SizedBox(
              height: 72,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Expanded(child: PulsePlaceholder()),
                  Text(goals.jobStatus ?? 'Building your map'),
                ],
              ),
            )
          else
            FilledButton(
              onPressed: () async {
                await context.read<GoalsController>().createGoal(
                  topic: _topic.text.trim(),
                  purpose: _purpose.text.trim(),
                  depth: _depth,
                  minutes: _minutes.round(),
                );
                if (context.mounted && context.read<GoalsController>().goal != null) {
                  await context.read<GraphController>().loadWorkspace();
                  if (context.mounted) context.go('/graph');
                }
              },
              child: const Text('Build my map'),
            ),
          if (goals.error != null) Text(goals.error!),
        ],
      ),
    );
  }
}
