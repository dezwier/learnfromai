import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/pulse_placeholder.dart';
import '../../core/widgets/study_card.dart';
import '../goals/goals_controller.dart';
import '../knowledge_graph/graph_controller.dart';
import '../learning/learn_controller.dart';

class TrajectoryScreen extends StatelessWidget {
  const TrajectoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final goals = context.watch<GoalsController>();
    final learn = context.watch<LearnController>();
    final items = goals.goals.isNotEmpty ? goals.goals : (goals.goal == null ? <Map<String, dynamic>>[] : [goals.goal!]);
    if (goals.loading && items.isEmpty) {
      return const Padding(padding: studyPagePadding, child: SizedBox(height: 220, child: PulsePlaceholder()));
    }
    return ListView(
      padding: studyPagePadding,
      children: [
        if (items.isEmpty)
          const Text('No trajectories yet. Add a topic from the graph.')
        else
          for (final item in items) ...[
            _TrajectoryRow(item: item, path: _path(item, goals)),
            const SizedBox(height: 12),
          ],
        if (learn.feedback != null) ...[
          const SizedBox(height: 4),
          Text('Score ${learn.feedback!['feedback']?['score'] ?? '—'}'),
        ],
        if (goals.error != null) ...[const SizedBox(height: 12), Text(goals.error!)],
        if (learn.error != null) ...[const SizedBox(height: 12), Text(learn.error!)],
      ],
    );
  }

  String _path(Map<String, dynamic> item, GoalsController goals) {
    final sequence = [for (final step in (item['sequence'] as List?) ?? const []) step.toString()];
    if (sequence.isNotEmpty) return sequence.join(' → ');
    final step = goals.recommendation?['step'];
    if (step is Map && step['concept_title'] != null) return step['concept_title'].toString();
    return item['topic']?.toString() ?? '';
  }
}

class _TrajectoryRow extends StatelessWidget {
  const _TrajectoryRow({required this.item, required this.path});

  final Map<String, dynamic> item;
  final String path;

  @override
  Widget build(BuildContext context) {
    final title = item['title']?.toString() ?? 'Trajectory';
    final id = item['id']?.toString();
    final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
            if (path.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(path, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: muted, height: 1.3)),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton(
                  onPressed: id == null ? null : () => _start(context, id),
                  child: const Text('Start'),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'See in graph',
                  onPressed: () {
                    context.read<GraphController>().focusTrajectory(item['trajectory_id']?.toString());
                    context.go('/graph');
                  },
                  icon: const Icon(Icons.account_tree_outlined),
                ),
                IconButton(
                  tooltip: 'Rename',
                  onPressed: id == null ? null : () => _rename(context, id, title),
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  tooltip: 'Delete',
                  onPressed: id == null ? null : () => _delete(context, id, title),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _start(BuildContext context, String id) async {
    final learn = context.read<LearnController>();
    await learn.start(id);
    if (!context.mounted || learn.error != null) return;
    context.go('/learn');
  }

  Future<void> _rename(BuildContext context, String id, String title) async {
    final controller = TextEditingController(text: title);
    final next = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'Name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (next == null || next.trim().isEmpty || !context.mounted) return;
    await context.read<GoalsController>().rename(id, next);
  }

  Future<void> _delete(BuildContext context, String id, String title) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete trajectory'),
        content: Text('Remove $title? The shared graph stays.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final removed = await context.read<GoalsController>().remove(id);
    if (!removed || !context.mounted) return;
    await context.read<GraphController>().focusTrajectory(null);
  }
}
