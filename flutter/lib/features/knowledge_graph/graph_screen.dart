import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/theme_controller.dart';
import '../../core/widgets/gradient_top_bar.dart';
import '../../core/widgets/pulse_placeholder.dart';
import '../../core/widgets/study_card.dart';
import '../auth/auth_controller.dart';
import 'graph_controller.dart';
import 'graph_layout.dart';

class GraphScreen extends StatefulWidget {
  const GraphScreen({super.key});

  @override
  State<GraphScreen> createState() => _GraphScreenState();
}

class _GraphScreenState extends State<GraphScreen> {
  final _camera = TransformationController();
  String? _framedSignature;
  bool _userMoved = false;
  int _shown = 0;
  int _floor = 0;
  int _ceiling = 0;
  double _gestureScale = 1;

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
    _syncDepth(nodes);
    final visibleNodes = [for (final node in nodes) if (_levelOf(node) <= _shown) node];
    final visibleIds = {for (final node in visibleNodes) node['concept_id'].toString()};
    final visibleEdges = [
      for (final edge in edges)
        if (visibleIds.contains('${edge['from_concept_id']}') && visibleIds.contains('${edge['to_concept_id']}')) edge,
    ];
    final layout = _layout(visibleNodes, visibleEdges);
    final byId = {for (final node in visibleNodes) node['concept_id'].toString(): node};
    final placed = [for (final point in layout.points) _Placed(byId[point.id]!, point.dx, point.dy)];
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
            LayoutBuilder(
              builder: (context, constraints) {
                final signature = '$_shown:${layout.points.map((point) => point.id).join(',')}:${layout.frames.length}:${layout.width.round()}x${layout.height.round()}';
                if (!_userMoved && signature != _framedSignature && constraints.maxWidth > 0 && placed.isNotEmpty) {
                  final next = _cameraFor(layout, placed, constraints.biggest);
                  _framedSignature = signature;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && !_userMoved) _camera.value = next;
                  });
                }
                return InteractiveViewer(
                  transformationController: _camera,
                  alignment: Alignment.topLeft,
                  constrained: false,
                  minScale: 0.85,
                  maxScale: 1.35,
                  boundaryMargin: const EdgeInsets.all(double.infinity),
                  onInteractionStart: (_) {
                    _userMoved = true;
                    _gestureScale = _camera.value.getMaxScaleOnAxis();
                  },
                  onInteractionEnd: (_) => _finishZoom(),
                  child: SizedBox(
                    width: layout.width,
                    height: layout.height,
                    child: Stack(
                      children: [
                        Positioned.fill(child: CustomPaint(painter: _EdgePainter(placed: placed, edges: edges, frames: layout.frames))),
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
          if (graph.generationPending)
            Positioned(
              left: 16,
              right: 16,
              bottom: 84,
              child: StudyCard(
                dense: true,
                eyebrow: 'Pending generation',
                title: graph.generationSubject,
                subtitle: graph.generationLabel,
                footer: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(value: graph.generationFraction, minHeight: 8),
                ),
              ),
            ),
          if (graph.error != null && !graph.generationPending && !graph.deleting)
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
          if (graph.deleting)
            const Positioned(
              left: 16,
              right: 16,
              bottom: 84,
              child: SizedBox(height: 44, child: PulsePlaceholder()),
            ),
          Positioned(
            left: 16,
            bottom: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton.filledTonal(
                  tooltip: 'Show more detail',
                  onPressed: graph.extending || graph.deleting || _shown >= _ceiling
                      ? null
                      : () => setState(() {
                            _shown += 1;
                            _userMoved = false;
                            _framedSignature = null;
                          }),
                  icon: const Icon(Icons.zoom_in),
                ),
                const SizedBox(height: 8),
                IconButton.filledTonal(
                  tooltip: 'Show less detail',
                  onPressed: graph.extending || graph.deleting || _shown <= _floor
                      ? null
                      : () => setState(() {
                            _shown -= 1;
                            _userMoved = false;
                            _framedSignature = null;
                          }),
                  icon: const Icon(Icons.zoom_out),
                ),
              ],
            ),
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
              child: _ExtendCard(request: request),
            ),
        ],
      ),
    );
  }

  Matrix4 _cameraFor(GraphLayout layout, List<_Placed> placed, Size viewport) {
    var minX = placed.first.dx;
    var minY = placed.first.dy;
    var maxX = placed.first.dx + graphNodeWidth;
    var maxY = placed.first.dy + graphNodeHeight;
    for (final item in placed.skip(1)) {
      if (item.dx < minX) minX = item.dx;
      if (item.dy < minY) minY = item.dy;
      if (item.dx + graphNodeWidth > maxX) maxX = item.dx + graphNodeWidth;
      if (item.dy + graphNodeHeight > maxY) maxY = item.dy + graphNodeHeight;
    }
    for (final frame in layout.frames) {
      if (frame.left < minX) minX = frame.left;
      if (frame.top < minY) minY = frame.top;
      if (frame.left + frame.width > maxX) maxX = frame.left + frame.width;
      if (frame.top + frame.height > maxY) maxY = frame.top + frame.height;
    }
    final boundsW = (maxX - minX) + 96;
    final boundsH = (maxY - minY) + 96;
    var scale = viewport.width / boundsW;
    final heightScale = viewport.height / boundsH;
    if (heightScale < scale) scale = heightScale;
    if (scale < 1) scale = 1;
    if (scale > 1.15) scale = 1.15;
    final cx = (minX + maxX) / 2;
    final cy = (minY + maxY) / 2;
    return Matrix4.identity()
      ..translateByDouble(viewport.width / 2, viewport.height / 2, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1)
      ..translateByDouble(-cx, -cy, 0, 1);
  }

  void _syncDepth(List<Map<String, dynamic>> nodes) {
    if (nodes.isEmpty) {
      _floor = 0;
      _ceiling = 0;
      _shown = 0;
      return;
    }
    var floor = _levelOf(nodes.first);
    var ceiling = floor;
    for (final node in nodes.skip(1)) {
      final level = _levelOf(node);
      if (level < floor) floor = level;
      if (level > ceiling) ceiling = level;
    }
    _floor = floor;
    _ceiling = ceiling;
    if (_shown < floor) _shown = floor;
    if (_shown > ceiling) _shown = ceiling;
  }

  void _finishZoom() {
    final now = _camera.value.getMaxScaleOnAxis();
    final ratio = _gestureScale == 0 ? 1.0 : now / _gestureScale;
    if (ratio > 1.08 && _shown < _ceiling) {
      setState(() {
        _shown += 1;
        _userMoved = false;
        _framedSignature = null;
      });
      return;
    }
    if (ratio < 0.92 && _shown > _floor) {
      setState(() {
        _shown -= 1;
        _userMoved = false;
        _framedSignature = null;
      });
      return;
    }
    if ((ratio - 1).abs() > 0.04) {
      setState(() {
        _userMoved = false;
        _framedSignature = null;
      });
    }
  }
}

int _levelOf(Map<String, dynamic> node) {
  final raw = node['level'];
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse('$raw') ?? 0;
}

class _ExtendCard extends StatelessWidget {
  const _ExtendCard({required this.request});

  final Map<String, dynamic> request;

  @override
  Widget build(BuildContext context) {
    final status = request['status']?.toString() ?? '';
    final pending = status == 'queued' || status == 'running';
    final message = request['progress_message']?.toString();
    final failed = status == 'failed';
    final error = request['error_message']?.toString();
    return StudyCard(
      dense: true,
      eyebrow: pending ? 'Pending generation' : '${request['author'] ?? 'Someone'} · $status',
      title: request['instruction']?.toString() ?? 'Extend',
      subtitle: pending
          ? (message != null && message.isNotEmpty ? message : 'Waiting to generate')
          : failed && error != null && error.isNotEmpty
              ? error
              : _when(request['created_at']?.toString()),
      footer: pending
          ? ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: request['progress_fraction'] is num ? (request['progress_fraction'] as num).toDouble() : 0.2,
                minHeight: 8,
              ),
            )
          : null,
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

class _Placed {
  const _Placed(this.node, this.dx, this.dy);

  final Map<String, dynamic> node;
  final double dx;
  final double dy;
}

GraphLayout _layout(List<Map<String, dynamic>> nodes, List<Map<String, dynamic>> edges) {
  return layoutGraph(
    [for (final node in nodes) node['concept_id'].toString()],
    [
      for (final edge in edges)
        if (edge['from_concept_id'] != null && edge['to_concept_id'] != null)
          GraphEdge(
            from: edge['from_concept_id'].toString(),
            to: edge['to_concept_id'].toString(),
            type: edge['type']?.toString() ?? '',
          ),
    ],
  );
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
          width: graphNodeWidth,
          height: graphNodeHeight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Text(
              node['title']?.toString() ?? 'Concept',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, height: 1.15, color: ink),
            ),
          ),
        ),
      ),
    );
  }
}

class _EdgePainter extends CustomPainter {
  const _EdgePainter({required this.placed, required this.edges, required this.frames});

  final List<_Placed> placed;
  final List<Map<String, dynamic>> edges;
  final List<GraphFrame> frames;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()
      ..color = const Color(0xFF1F4B6E).withValues(alpha: 0.06)
      ..style = PaintingStyle.fill;
    final border = Paint()
      ..color = const Color(0xFF1F4B6E).withValues(alpha: 0.28)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final frame in frames) {
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(frame.left, frame.top, frame.width, frame.height),
        const Radius.circular(28),
      );
      canvas.drawRRect(rect, fill);
      canvas.drawRRect(rect, border);
    }
    final centers = {
      for (final item in placed) item.node['concept_id'].toString(): Offset(item.dx + graphNodeWidth / 2, item.dy + graphNodeHeight / 2),
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
  bool shouldRepaint(covariant _EdgePainter oldDelegate) =>
      oldDelegate.placed != oldDelegate.placed || oldDelegate.edges != oldDelegate.edges || oldDelegate.frames != oldDelegate.frames;
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
