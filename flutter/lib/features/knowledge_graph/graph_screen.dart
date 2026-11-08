import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/theme_controller.dart';
import '../../core/widgets/gradient_top_bar.dart';
import '../../core/widgets/pulse_placeholder.dart';
import '../../core/widgets/study_card.dart';
import '../auth/auth_controller.dart';
import 'graph_controller.dart';

const _nodeWidth = 168.0;
const _nodeHeight = 72.0;

class GraphScreen extends StatefulWidget {
  const GraphScreen({super.key});

  @override
  State<GraphScreen> createState() => _GraphScreenState();
}

class _GraphScreenState extends State<GraphScreen> {
  final _camera = TransformationController();
  bool _framed = false;
  bool _userMoved = false;

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final graph = context.watch<GraphController>();
    final nodes = [
      for (final raw in (graph.workspace?['nodes'] as List?) ?? const []) Map<String, dynamic>.from(raw as Map),
    ];
    final edges = [
      for (final raw in (graph.workspace?['edges'] as List?) ?? const []) Map<String, dynamic>.from(raw as Map),
    ];
    final placed = _place(nodes, edges);
    final width = placed.isEmpty ? 360.0 : placed.map((item) => item.dx).reduce((a, b) => a > b ? a : b) + _nodeWidth + 48;
    final height = placed.isEmpty ? 240.0 : placed.map((item) => item.dy).reduce((a, b) => a > b ? a : b) + _nodeHeight + 48;
    return Scaffold(
      appBar: GradientTopBar(
        title: 'Graph',
        actions: [
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
            LayoutBuilder(
              builder: (context, constraints) {
                if (!_framed && constraints.maxWidth > 0 && placed.isNotEmpty) {
                  final next = _cameraFor(placed, constraints.biggest);
                  _userMoved = false;
                  _framed = true;
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
                            child: _GraphNode(node: item.node, onTap: () => _openNode(context, item.node)),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          if (graph.extending)
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
              onPressed: graph.extending ? null : () => _ask(context, null),
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

  Matrix4 _cameraFor(List<_Placed> placed, Size viewport) {
    var minX = placed.first.dx;
    var minY = placed.first.dy;
    var maxX = placed.first.dx + _nodeWidth;
    var maxY = placed.first.dy + _nodeHeight;
    for (final item in placed.skip(1)) {
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
  const _GraphNode({required this.node, required this.onTap});

  final Map<String, dynamic> node;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    return Material(
      color: Color.alphaBlend(const Color(0xFF1F4B6E).withValues(alpha: 0.12), Theme.of(context).colorScheme.surface),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: const Color(0xFF1F4B6E).withValues(alpha: 0.45)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: SizedBox(
          width: _nodeWidth,
          height: _nodeHeight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Text(
              node['title']?.toString() ?? 'Concept',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: FontWeight.w700, height: 1.15, color: ink),
            ),
          ),
        ),
      ),
    );
  }
}

class _EdgePainter extends CustomPainter {
  const _EdgePainter({required this.placed, required this.edges});

  final List<_Placed> placed;
  final List<Map<String, dynamic>> edges;

  @override
  void paint(Canvas canvas, Size size) {
    final centers = {
      for (final item in placed) item.node['concept_id'].toString(): Offset(item.dx + _nodeWidth / 2, item.dy + _nodeHeight / 2),
    };
    for (final edge in edges) {
      final from = centers[edge['from_concept_id']?.toString()];
      final to = centers[edge['to_concept_id']?.toString()];
      if (from == null || to == null) continue;
      final prerequisite = edge['type'] == 'prerequisite';
      final paint = Paint()
        ..color = (prerequisite ? const Color(0xFF1F4B6E) : const Color(0xFF6B7280)).withValues(alpha: 0.7)
        ..strokeWidth = prerequisite ? 2.2 : 1.4
        ..style = PaintingStyle.stroke;
      canvas.drawPath(
        Path()
          ..moveTo(from.dx, from.dy)
          ..cubicTo((from.dx + to.dx) / 2, from.dy, (from.dx + to.dx) / 2, to.dy, to.dx, to.dy),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _EdgePainter oldDelegate) => oldDelegate.placed != oldDelegate.placed || oldDelegate.edges != oldDelegate.edges;
}

class _NodeSheet extends StatefulWidget {
  const _NodeSheet({required this.node, required this.onExtend});

  final Map<String, dynamic> node;
  final Future<void> Function(String instruction) onExtend;

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
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.node['title']?.toString() ?? 'Concept', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
          if (summary.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(summary),
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
        ],
      ),
    );
  }
}
