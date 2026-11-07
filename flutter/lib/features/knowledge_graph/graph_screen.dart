import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/pulse_placeholder.dart';
import '../../core/widgets/study_card.dart';
import '../goals/goals_controller.dart';
import '../learning/learn_controller.dart';
import 'graph_controller.dart';

const _nodeWidth = 168.0;
const _nodeHeight = 88.0;

bool _placeholder(String title, Set<String> titles) {
  final folded = title.trim().toLowerCase();
  if (folded.endsWith(' practice') || folded == 'topic' || folded == 'topic structure' || folded == 'topic origins') {
    return true;
  }
  for (final suffix in [' structure', ' origins']) {
    if (folded.endsWith(suffix) && titles.contains(folded.substring(0, folded.length - suffix.length).trim())) {
      return true;
    }
  }
  return false;
}

class GraphScreen extends StatefulWidget {
  const GraphScreen({super.key});

  @override
  State<GraphScreen> createState() => _GraphScreenState();
}

class _GraphScreenState extends State<GraphScreen> {
  final _camera = TransformationController();
  String _framed = '';
  bool _userMoved = false;

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final graph = context.watch<GraphController>();
    if (graph.loading && graph.workspace == null) {
      return const Padding(padding: studyPagePadding, child: SizedBox(height: 320, child: PulsePlaceholder()));
    }
    final parsed = <Map<String, dynamic>>[
      for (final raw in (graph.workspace?['nodes'] as List?) ?? []) Map<String, dynamic>.from(raw as Map),
    ];
    final titles = {for (final node in parsed) (node['title']?.toString() ?? '').toLowerCase()};
    final nodes = [for (final node in parsed) if (!_placeholder(node['title']?.toString() ?? '', titles)) node];
    final edges = [
      for (final raw in (graph.workspace?['edges'] as List?) ?? []) Map<String, dynamic>.from(raw as Map),
    ];
    final onPath = {
      for (final id in (graph.workspace?['trajectory_concept_ids'] as List?) ?? []) id.toString(),
    };
    final placed = _place(nodes, edges);
    final width = placed.isEmpty ? 360.0 : placed.map((item) => item.dx).reduce((a, b) => a > b ? a : b) + _nodeWidth + 48;
    final height = placed.isEmpty ? 240.0 : placed.map((item) => item.dy).reduce((a, b) => a > b ? a : b) + _nodeHeight + 48;
    return Stack(
      children: [
        Column(
      children: [
        Expanded(
          child: nodes.isEmpty
              ? ListView(
                  padding: studyPagePadding,
                  children: [
                    const StudyCard(
                      eyebrow: 'GRAPH',
                      title: 'Your graph is empty',
                      subtitle: 'A goal adds the first nodes. Later topics reuse nodes you already have.',
                    ),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: () => context.go('/onboarding'), child: const Text('Set a learning goal')),
                  ],
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final signature = (onPath.toList()..sort()).join(',');
                    if (signature != _framed && constraints.maxWidth > 0 && placed.isNotEmpty) {
                      final next = _cameraFor(placed, onPath, constraints.biggest);
                      _userMoved = false;
                      _framed = signature;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted && !_userMoved) _camera.value = next;
                      });
                    }
                    return InteractiveViewer(
                  transformationController: _camera,
                  alignment: Alignment.topLeft,
                  constrained: false,
                  minScale: 0.2,
                  maxScale: 2.8,
                  boundaryMargin: const EdgeInsets.all(double.infinity),
                  onInteractionStart: (_) => _userMoved = true,
                  child: SizedBox(
                    width: width,
                    height: height,
                    child: Stack(
                      children: [
                        Positioned.fill(child: CustomPaint(painter: _EdgePainter(placed: placed, edges: edges))),
                        for (final item in placed)
                          Positioned(
                            left: item.dx,
                            top: item.dy,
                            child: _GraphNode(
                              node: item.node,
                              onPath: onPath.contains(item.node['concept_id']?.toString()),
                              onTap: () => _openNode(context, item.node),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
                  },
                ),
        ),
        if (graph.impact != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ImpactPanel(impact: (graph.impact!['impact'] as Map?)?.cast<String, dynamic>() ?? {}),
                const SizedBox(height: 8),
                if (graph.proposalId != null)
                  FilledButton(
                    onPressed: () async {
                      final goalId = context.read<GoalsController>().goal?['id']?.toString() ?? graph.workspace?['goal']?['id']?.toString();
                      if (goalId == null) return;
                      await graph.accept(goalId);
                    },
                    child: const Text('Accept change'),
                  ),
              ],
            ),
          ),
        ],
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton.extended(
            onPressed: graph.loading ? null : () => _addTopic(context),
            icon: const Icon(Icons.add),
            label: const Text('Add topic'),
          ),
        ),
      ],
    );
  }

  Future<void> _addTopic(BuildContext context) async {
    final controller = TextEditingController();
    final topic = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(sheetContext).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Add a topic', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
            const SizedBox(height: 8),
            const Text('It is added to the one shared graph, then you can learn it.'),
            const SizedBox(height: 12),
            TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'Topic', filled: true)),
            const SizedBox(height: 12),
            FilledButton(onPressed: () => Navigator.pop(sheetContext, controller.text.trim()), child: const Text('Add')),
          ],
        ),
      ),
    );
    controller.dispose();
    if (topic == null || topic.isEmpty || !context.mounted) return;
    await context.read<GoalsController>().createGoal(topic: topic, purpose: topic, depth: 'overview', minutes: 120);
    if (!context.mounted) return;
    await context.read<GraphController>().focusTrajectory(null);
  }

  Matrix4 _cameraFor(List<_Placed> placed, Set<String> onPath, Size viewport) {
    final focus = [for (final item in placed) if (onPath.contains(item.node['concept_id']?.toString())) item];
    final targets = focus.isEmpty ? placed : focus;
    var minX = targets.first.dx;
    var minY = targets.first.dy;
    var maxX = targets.first.dx + _nodeWidth;
    var maxY = targets.first.dy + _nodeHeight;
    for (final item in targets.skip(1)) {
      if (item.dx < minX) minX = item.dx;
      if (item.dy < minY) minY = item.dy;
      if (item.dx + _nodeWidth > maxX) maxX = item.dx + _nodeWidth;
      if (item.dy + _nodeHeight > maxY) maxY = item.dy + _nodeHeight;
    }
    final boundsW = (maxX - minX) + 96;
    final boundsH = (maxY - minY) + 96;
    var scale = viewport.width / boundsW;
    final heightScale = viewport.height / boundsH;
    if (heightScale < scale) scale = heightScale;
    if (scale < 0.45) scale = 0.45;
    if (scale > 1.15) scale = 1.15;
    final cx = (minX + maxX) / 2;
    final cy = (minY + maxY) / 2;
    return Matrix4.identity()
      ..translateByDouble(viewport.width / 2, viewport.height / 2, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1)
      ..translateByDouble(-cx, -cy, 0, 1);
  }

  Future<void> _openNode(BuildContext context, Map<String, dynamic> node) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _NodeSheet(
        node: node,
        onStart: () async {
          Navigator.pop(sheetContext);
          final goalId = node['goal_id']?.toString() ?? context.read<GoalsController>().goal?['id']?.toString();
          final conceptId = node['concept_id']?.toString();
          if (goalId == null || !context.mounted) return;
          await context.read<LearnController>().start(goalId, conceptId: conceptId);
          if (context.mounted) context.go('/learn');
        },
        onExpand: (instruction) async {
          Navigator.pop(sheetContext);
          final graph = context.read<GraphController>();
          final graphId = node['graph_id']?.toString() ?? graph.workspace?['goal']?['graph_id']?.toString();
          final releaseId = node['release_id']?.toString() ?? graph.workspace?['goal']?['release_id']?.toString();
          final conceptId = node['concept_id']?.toString();
          if (graphId == null || releaseId == null || conceptId == null) return;
          await graph.expand(graphId, releaseId, conceptId, instruction);
        },
      ),
    );
  }
}

class _Placed {
  const _Placed(this.node, this.dx, this.dy);

  final Map<String, dynamic> node;
  final double dx;
  final double dy;
}

List<_Placed> _place(List<Map<String, dynamic>> nodes, List<Map<String, dynamic>> edges) {
  final ids = [for (final node in nodes) node['concept_id'].toString()];
  final depth = {for (final id in ids) id: 0};
  final children = {for (final id in ids) id: <String>[]};
  final incoming = {for (final id in ids) id: 0};
  for (final edge in edges) {
    final type = edge['type']?.toString();
    if (type != 'contains' && type != 'prerequisite') continue;
    final from = edge['from_concept_id']?.toString();
    final to = edge['to_concept_id']?.toString();
    if (from == null || to == null || !depth.containsKey(from) || !depth.containsKey(to)) continue;
    children[from]!.add(to);
    incoming[to] = incoming[to]! + 1;
  }
  final roots = [for (final id in ids) if (incoming[id] == 0) id];
  final queue = <String>[...(roots.isEmpty ? ids : roots)];
  final seen = <String>{};
  while (queue.isNotEmpty) {
    final id = queue.removeAt(0);
    if (!seen.add(id)) continue;
    for (final child in children[id] ?? const <String>[]) {
      if (depth[child]! < depth[id]! + 1) depth[child] = depth[id]! + 1;
      queue.add(child);
    }
  }
  final columns = <int, List<String>>{};
  for (final id in ids) {
    columns.putIfAbsent(depth[id]!, () => []).add(id);
  }
  final byId = {for (final node in nodes) node['concept_id'].toString(): node};
  final placed = <_Placed>[];
  final depths = columns.keys.toList()..sort();
  for (final column in depths) {
    final columnIds = columns[column]!;
    for (var index = 0; index < columnIds.length; index++) {
      placed.add(_Placed(byId[columnIds[index]]!, 20 + column * 224, 20 + index * 112.0));
    }
  }
  return placed;
}

class _GraphNode extends StatelessWidget {
  const _GraphNode({required this.node, required this.onPath, required this.onTap});

  final Map<String, dynamic> node;
  final bool onPath;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = node['mastery_status']?.toString() ?? 'unknown';
    final proposed = node['status']?.toString() == 'proposed';
    final removed = node['status']?.toString() == 'removed';
    final tint = masteryColor(status);
    final change = node['change']?.toString();
    final card = Material(
      color: Color.alphaBlend(tint.withValues(alpha: 0.16), Theme.of(context).colorScheme.surface),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: onPath ? Theme.of(context).colorScheme.primary : tint.withValues(alpha: 0.45), width: onPath ? 2.4 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: SizedBox(
          width: _nodeWidth,
          height: _nodeHeight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  node['title']?.toString() ?? 'Concept',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700, height: 1.15),
                ),
                const Spacer(),
                Text(masteryLabel(status), style: TextStyle(color: tint, fontSize: 12, fontWeight: FontWeight.w700)),
                if (change != null && change.isNotEmpty)
                  Text(change == 'new' ? 'New' : change == 'changed' ? 'Changed' : 'Removed', style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ),
        ),
      ),
    );
    final faded = Opacity(opacity: removed ? 0.45 : 1, child: card);
    if (!proposed) return faded;
    return CustomPaint(foregroundPainter: _DashedBorderPainter(color: tint), child: faded);
  }
}

class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(18)));
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        canvas.drawPath(metric.extractPath(distance, distance + 6), paint);
        distance += 10;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) => oldDelegate.color != color;
}

class _EdgePainter extends CustomPainter {
  const _EdgePainter({required this.placed, required this.edges});

  final List<_Placed> placed;
  final List<Map<String, dynamic>> edges;

  @override
  void paint(Canvas canvas, Size size) {
    final centers = {for (final item in placed) item.node['concept_id'].toString(): Offset(item.dx + _nodeWidth / 2, item.dy + _nodeHeight / 2)};
    for (final edge in edges) {
      final from = centers[edge['from_concept_id']?.toString()];
      final to = centers[edge['to_concept_id']?.toString()];
      if (from == null || to == null) continue;
      final proposed = edge['status']?.toString() == 'proposed';
      final paint = Paint()
        ..color = (edge['type'] == 'prerequisite' ? const Color(0xFF1F4B6E) : const Color(0xFF6B7280)).withValues(alpha: proposed ? 0.45 : 0.7)
        ..strokeWidth = edge['type'] == 'prerequisite' ? 2.2 : 1.4
        ..style = PaintingStyle.stroke;
      final path = Path()
        ..moveTo(from.dx, from.dy)
        ..cubicTo((from.dx + to.dx) / 2, from.dy, (from.dx + to.dx) / 2, to.dy, to.dx, to.dy);
      if (!proposed) {
        canvas.drawPath(path, paint);
        continue;
      }
      for (final metric in path.computeMetrics()) {
        var distance = 0.0;
        while (distance < metric.length) {
          canvas.drawPath(metric.extractPath(distance, distance + 8), paint);
          distance += 14;
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _EdgePainter oldDelegate) => oldDelegate.placed != oldDelegate.placed || oldDelegate.edges != oldDelegate.edges;
}

class _NodeSheet extends StatelessWidget {
  const _NodeSheet({required this.node, required this.onStart, required this.onExpand});

  final Map<String, dynamic> node;
  final Future<void> Function() onStart;
  final Future<void> Function(String instruction) onExpand;

  @override
  Widget build(BuildContext context) {
    final objectives = (node['objectives'] as List?) ?? [];
    final status = node['mastery_status']?.toString() ?? 'unknown';
    final estimate = node['estimate'] ?? 0;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.paddingOf(context).bottom),
      child: ListView(
        shrinkWrap: true,
        children: [
          StudyCard(
            eyebrow: 'CONCEPT',
            tint: masteryColor(status),
            title: node['title']?.toString() ?? 'Concept',
            subtitle: node['summary']?.toString(),
            footer: objectives.isEmpty
                ? null
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final objective in objectives)
                        if (((objective as Map)['statement']?.toString() ?? '').isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text((objective)['statement'].toString()),
                          ),
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          StudyCard(
            eyebrow: 'PROGRESS',
            tint: masteryColor(status),
            title: masteryLabel(status),
            subtitle: 'Estimate $estimate',
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: onStart, child: const Text('Start')),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () async {
              final instruction = await _ask(context);
              if (instruction == null || instruction.isEmpty) return;
              await onExpand(instruction);
            },
            child: const Text('Expand branch'),
          ),
        ],
      ),
    );
  }

  Future<String?> _ask(BuildContext context) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Expand branch'),
        content: TextField(controller: controller, decoration: const InputDecoration(labelText: 'What is missing?')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Propose')),
        ],
      ),
    );
    controller.dispose();
    return value;
  }
}

class ImpactPanel extends StatelessWidget {
  const ImpactPanel({super.key, required this.impact});

  final Map<String, dynamic> impact;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StudyCard(dense: true, tint: const Color(0xFF2E7D4F), eyebrow: 'KEPT', title: '${impact['preserved_objectives'] ?? 0} skills kept'),
        const SizedBox(height: 8),
        StudyCard(dense: true, eyebrow: 'NEW', title: '${impact['new_objectives'] ?? 0} new'),
        const SizedBox(height: 8),
        StudyCard(dense: true, tint: const Color(0xFF8A5A00), eyebrow: 'RECHECK', title: '${impact['reassessment_objectives'] ?? 0} needs recheck'),
      ],
    );
  }
}
