import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/theme_controller.dart';
import '../../core/widgets/gradient_top_bar.dart';
import '../../core/widgets/pulse_placeholder.dart';
import '../../core/widgets/study_card.dart';
import '../auth/auth_controller.dart';
import 'graph_controller.dart';
import 'topic_tree.dart';

class GraphScreen extends StatefulWidget {
  const GraphScreen({super.key});

  @override
  State<GraphScreen> createState() => _GraphScreenState();
}

class _GraphScreenState extends State<GraphScreen> {
  @override
  Widget build(BuildContext context) {
    final graph = context.watch<GraphController>();
    final nodes = [
      for (final raw in (graph.workspace?['nodes'] as List?) ?? const []) Map<String, dynamic>.from(raw as Map),
    ];
    final edges = [
      for (final raw in (graph.workspace?['edges'] as List?) ?? const []) Map<String, dynamic>.from(raw as Map),
    ];
    return Scaffold(
      appBar: GradientTopBar(
        title: 'Graph',
        actions: [
          IconButton(tooltip: 'Settings', onPressed: () => _showSettings(context), icon: const Icon(Icons.settings)),
          IconButton(
            tooltip: 'Theme',
            onPressed: () {
              final themes = context.read<ThemeController>();
              final next = switch (themes.mode) {
                ThemeMode.system => ThemeMode.light,
                ThemeMode.light => ThemeMode.dark,
                ThemeMode.dark => ThemeMode.system,
              };
              themes.setMode(next);
            },
            icon: const Icon(Icons.brightness_6),
          ),
          IconButton(tooltip: 'Past extends', onPressed: () => _showHistory(context), icon: const Icon(Icons.history)),
          IconButton(
            tooltip: 'Sign out',
            onPressed: () => context.read<AuthController>().signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Stack(
        children: [
          if (graph.loading && graph.workspace == null)
            const Padding(padding: studyPagePadding, child: SizedBox(height: 320, child: PulsePlaceholder()))
          else if (nodes.isEmpty)
            ListView(
              padding: studyPagePadding,
              children: [
                const StudyCard(
                  eyebrow: 'GRAPH',
                  title: 'The graph is empty',
                  subtitle: 'Extend it with a topic. Later requests add nodes and edges to this same graph.',
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: graph.extending ? null : () => _ask(context, null), child: const Text('Extend the graph')),
              ],
            )
          else
            TopicTree(nodes: nodes, edges: edges, onOpen: (node) => _openNode(context, node)),
          if (graph.error != null && !graph.extending && !graph.deleting)
            Positioned(
              left: 16,
              right: 16,
              bottom: 84,
              child: Material(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(graph.error!, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
                ),
              ),
            ),
          if (graph.extending || graph.deleting)
            const Positioned(
              left: 16,
              right: 16,
              bottom: 84,
              child: SizedBox(height: 44, child: PulsePlaceholder()),
            ),
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton.extended(
              onPressed: graph.extending || graph.deleting ? null : () => _ask(context, null),
              icon: const Icon(Icons.add),
              label: const Text('Extend'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _ask(BuildContext context, Map<String, dynamic>? parent) async {
    final controller = TextEditingController();
    final instruction = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(sheetContext).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(parent == null ? 'Extend the graph' : 'Extend ${parent['title']}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
            const SizedBox(height: 8),
            const Text('The new nodes and edges are added to the shared graph.'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'What should be added?', filled: true),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: () => Navigator.pop(sheetContext, controller.text.trim()), child: const Text('Extend')),
          ],
        ),
      ),
    );
    controller.dispose();
    if (instruction == null || instruction.isEmpty || !context.mounted) return;
    await context.read<GraphController>().extend(instruction, parentConceptId: parent?['concept_id']?.toString());
  }

  Future<void> _openNode(BuildContext context, Map<String, dynamic> node) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _NodeSheet(
        node: node,
        onExtend: (instruction) async {
          Navigator.pop(sheetContext);
          await context.read<GraphController>().extend(instruction, parentConceptId: node['concept_id']?.toString());
        },
        onDelete: () async {
          final title = node['title']?.toString() ?? 'this node';
          final confirmed = await showDialog<bool>(
            context: sheetContext,
            builder: (dialogContext) => AlertDialog(
              title: Text('Delete $title?'),
              content: const Text('This removes the node and the edges connected to it. Other nodes stay.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
                TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Delete')),
              ],
            ),
          );
          if (confirmed != true || !sheetContext.mounted) return;
          final graph = context.read<GraphController>();
          final conceptId = node['concept_id']?.toString();
          Navigator.pop(sheetContext);
          if (conceptId == null) return;
          await graph.deleteNode(conceptId);
        },
      ),
    );
  }

  Future<void> _showSettings(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Settings', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: sheetContext,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('Delete the whole graph?'),
                    content: const Text('This removes every node and every edge. Past extend requests stay.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
                      TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Delete all')),
                    ],
                  ),
                );
                if (confirmed != true || !sheetContext.mounted) return;
                Navigator.pop(sheetContext);
                await context.read<GraphController>().clearGraph();
              },
              child: Text('Delete all nodes and edges', style: TextStyle(color: Theme.of(sheetContext).colorScheme.error)),
            ),
          ],
        ),
      ),
    );
  }

  void _showHistory(BuildContext context) {
    final requests = [
      for (final raw in (context.read<GraphController>().workspace?['extend_requests'] as List?) ?? const [])
        Map<String, dynamic>.from(raw as Map),
    ];
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          const Text('Past extends', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
          const SizedBox(height: 12),
          if (requests.isEmpty) const Text('No extends yet.'),
          for (final request in requests)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: StudyCard(
                dense: true,
                eyebrow: '${request['author'] ?? 'Someone'} · ${request['status'] ?? ''}',
                title: request['instruction']?.toString() ?? 'Extend',
                subtitle: _when(request['created_at']?.toString()),
              ),
            ),
        ],
      ),
    );
  }

}

String _when(String? raw) {
  if (raw == null || raw.isEmpty) return '';
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) return raw;
  final local = parsed.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${local.year}-$month-$day $hour:$minute';
}

class _NodeSheet extends StatefulWidget {
  const _NodeSheet({required this.node, required this.onExtend, required this.onDelete});

  final Map<String, dynamic> node;
  final Future<void> Function(String instruction) onExtend;
  final Future<void> Function() onDelete;

  @override
  State<_NodeSheet> createState() => _NodeSheetState();
}

class _NodeSheetState extends State<_NodeSheet> {
  final _instruction = TextEditingController();

  @override
  void dispose() {
    _instruction.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final summary = widget.node['summary']?.toString() ?? '';
    final explanation = widget.node['explanation']?.toString() ?? '';
    final range = explanation.isNotEmpty ? explanation : summary;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.node['title']?.toString() ?? 'Concept', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
          if (range.isNotEmpty) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.4),
              child: SingleChildScrollView(child: Text(range)),
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _instruction,
            decoration: const InputDecoration(labelText: 'Extend this node', filled: true),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () {
              final text = _instruction.text.trim();
              if (text.isEmpty) return;
              widget.onExtend(text);
            },
            child: const Text('Extend'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: widget.onDelete,
            child: Text('Delete node', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
  }
}
