import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/theme_controller.dart';
import '../../core/widgets/gradient_top_bar.dart';
import '../../core/widgets/pulse_placeholder.dart';
import '../../core/widgets/study_card.dart';
import '../auth/auth_controller.dart';
import 'dart:math' as math;

import 'cluster_layout.dart';
import 'graph_controller.dart';

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
      for (final raw in (graph.workspace?['nodes'] as List?) ?? const [])
        Map<String, dynamic>.from(raw as Map),
    ];
    final edges = [
      for (final raw in (graph.workspace?['edges'] as List?) ?? const [])
        Map<String, dynamic>.from(raw as Map),
    ];
    _syncDepth(nodes);
    final map = layoutClusters(nodes, edges);
    final byId = {
      for (final node in nodes) node['concept_id'].toString(): node,
    };
    final visibleLabels = [
      for (final label in map.labels)
        if (label.level <= _shown) label,
    ];
    final hexById = <String, ClusterHex>{
      for (final hex in map.hexes)
        if (hex.nodeId != null) hex.nodeId!: hex,
    };
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
          IconButton(
            tooltip: 'Past extends',
            onPressed: () => _showHistory(context),
            icon: const Icon(Icons.history),
          ),
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
            const Padding(
              padding: studyPagePadding,
              child: SizedBox(height: 320, child: PulsePlaceholder()),
            )
          else if (nodes.isEmpty)
            ListView(
              padding: studyPagePadding,
              children: [
                const StudyCard(
                  eyebrow: 'GRAPH',
                  title: 'The graph is empty',
                  subtitle:
                      'Extend it with a topic. Later requests add nodes and edges to this same graph.',
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: graph.extending ? null : () => _ask(context, null),
                  child: const Text('Extend the graph'),
                ),
              ],
            )
          else
            Positioned.fill(
              child: ColoredBox(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final signature =
                        '${map.hexes.length}:${map.width.round()}x${map.height.round()}';
                    if (!_userMoved &&
                        signature != _framedSignature &&
                        constraints.maxWidth > 0 &&
                        map.hexes.isNotEmpty) {
                      final next = _cameraFor(map, constraints.biggest);
                      _framedSignature = signature;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted && !_userMoved) _camera.value = next;
                      });
                    }
                    return InteractiveViewer(
                      transformationController: _camera,
                      alignment: Alignment.topLeft,
                      constrained: false,
                      minScale: _minGraphScale,
                      maxScale: _maxGraphScale,
                      boundaryMargin: const EdgeInsets.all(double.infinity),
                      onInteractionStart: (_) {
                        _userMoved = true;
                        _gestureScale = _camera.value.getMaxScaleOnAxis();
                      },
                      onInteractionEnd: (_) => _finishZoom(),
                      child: SizedBox(
                        width: map.width,
                        height: map.height,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _HexPainter(
                                  [
                                    ...map.hexes,
                                  ]..sort((a, b) => a.level.compareTo(b.level)),
                                  _shown,
                                ),
                              ),
                            ),
                            for (final hex in map.hexes)
                              if (hex.nodeId != null &&
                                  hex.filledAt(_shown) &&
                                  byId[hex.nodeId] != null)
                                Positioned(
                                  left: hex.cx - hex.radius,
                                  top: hex.cy - hex.radius,
                                  width: hex.radius * 2,
                                  height: hex.radius * 2,
                                  child: GestureDetector(
                                    onTap: () =>
                                        _openNode(context, byId[hex.nodeId]!),
                                  ),
                                ),
                            for (final label in visibleLabels)
                              if (byId[label.nodeId] != null)
                                _placedLabel(
                                  label,
                                  hexById[label.nodeId],
                                  _shown,
                                  () => _openNode(context, byId[label.nodeId]!),
                                ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
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
                  child: LinearProgressIndicator(
                    value: graph.generationFraction,
                    minHeight: 8,
                  ),
                ),
              ),
            ),
          if (graph.error != null &&
              !graph.generationPending &&
              !graph.deleting)
            Positioned(
              left: 16,
              right: 16,
              bottom: 84,
              child: Material(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    graph.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
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
                  onPressed:
                      graph.extending || graph.deleting || _shown >= _ceiling
                      ? null
                      : () => setState(() => _shown += 1),
                  icon: const Icon(Icons.zoom_in),
                ),
                const SizedBox(height: 8),
                IconButton.filledTonal(
                  tooltip: 'Show less detail',
                  onPressed:
                      graph.extending || graph.deleting || _shown <= _floor
                      ? null
                      : () => setState(() => _shown -= 1),
                  icon: const Icon(Icons.zoom_out),
                ),
              ],
            ),
          ),
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton.extended(
              onPressed: graph.extending || graph.deleting
                  ? null
                  : () => _ask(context, null),
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
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          20 + MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              parent == null ? 'Extend the graph' : 'Extend ${parent['title']}',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
            ),
            const SizedBox(height: 8),
            const Text(
              'The new nodes and edges are added to the shared graph.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'What should be added?',
                filled: true,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(sheetContext, controller.text.trim()),
              child: const Text('Extend'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (instruction == null || instruction.isEmpty || !context.mounted) return;
    await context.read<GraphController>().extend(
      instruction,
      parentConceptId: parent?['concept_id']?.toString(),
    );
  }

  Future<void> _openNode(
    BuildContext context,
    Map<String, dynamic> node,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _NodeSheet(
        node: node,
        onExtend: (instruction) async {
          Navigator.pop(sheetContext);
          await context.read<GraphController>().extend(
            instruction,
            parentConceptId: node['concept_id']?.toString(),
          );
        },
        onDelete: () async {
          final title = node['title']?.toString() ?? 'this node';
          final confirmed = await showDialog<bool>(
            context: sheetContext,
            builder: (dialogContext) => AlertDialog(
              title: Text('Delete $title?'),
              content: const Text(
                'This removes the node and the edges connected to it. Other nodes stay.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Delete'),
                ),
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

  void _showHistory(BuildContext context) {
    final graph = context.read<GraphController>();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => ListenableBuilder(
        listenable: graph,
        builder: (context, _) {
          final requests = [
            for (final raw
                in (graph.workspace?['extend_requests'] as List?) ?? const [])
              Map<String, dynamic>.from(raw as Map),
          ];
          return ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              const Text(
                'Past extends',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
              ),
              const SizedBox(height: 12),
              if (requests.isEmpty) const Text('No extends yet.'),
              for (final request in requests)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _ExtendCard(
                    request: request,
                    onDelete: () => _deleteExtend(sheetContext, request),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _deleteExtend(
    BuildContext sheetContext,
    Map<String, dynamic> request,
  ) async {
    final instruction = request['instruction']?.toString() ?? 'this extend';
    final confirmed = await showDialog<bool>(
      context: sheetContext,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete $instruction?'),
        content: const Text(
          'This removes the extend and the nodes and edges it added.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !sheetContext.mounted) return;
    final requestId = request['id']?.toString();
    if (requestId == null) return;
    await sheetContext.read<GraphController>().deleteRequest(requestId);
  }

  Matrix4 _cameraFor(ClusterMap map, Size viewport) {
    final boundsW = map.width + 48;
    final boundsH = map.height + 48;
    var scale = viewport.width / boundsW;
    final heightScale = viewport.height / boundsH;
    if (heightScale < scale) scale = heightScale;
    if (scale < _minGraphScale) scale = _minGraphScale;
    if (scale > 1.2) scale = 1.2;
    return Matrix4.identity()
      ..translateByDouble(viewport.width / 2, viewport.height / 2, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1)
      ..translateByDouble(-map.width / 2, -map.height / 2, 0, 1);
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
      setState(() => _shown += 1);
      return;
    }
    if (ratio < 0.92 && _shown > _floor) {
      setState(() => _shown -= 1);
    }
  }
}

const _minGraphScale = 0.05;
const _maxGraphScale = 32.0;

Widget _placedLabel(
  ClusterLabel label,
  ClusterHex? hex,
  int shown,
  VoidCallback onTap,
) {
  final radius = hex?.radius ?? clusterHexRadius;
  final height = (radius * 0.32).clamp(16.0, label.height);
  final width = math.min(label.width, math.max(48.0, radius * 1.35));
  // A split hexagon keeps its title in the upper point, clear of the children.
  final shift = hex != null && hex.outlineAt(shown)
      ? -math.min(hex.radius * 0.46, math.max(0.0, hex.radius - height))
      : 0.0;
  return Positioned(
    left: label.cx - width / 2,
    top: label.cy + shift - height / 2,
    child: _ClusterPill(
      label: label,
      width: width,
      height: height,
      onTap: onTap,
    ),
  );
}

int _levelOf(Map<String, dynamic> node) {
  final raw = node['level'];
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse('$raw') ?? 0;
}

class _ExtendCard extends StatelessWidget {
  const _ExtendCard({required this.request, required this.onDelete});

  final Map<String, dynamic> request;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final status = request['status']?.toString() ?? '';
    final pending = status == 'queued' || status == 'running';
    final message = request['progress_message']?.toString();
    final failed = status == 'failed';
    final error = request['error_message']?.toString();
    return StudyCard(
      dense: true,
      eyebrow: pending
          ? 'Pending generation'
          : '${request['author'] ?? 'Someone'} · $status',
      title: request['instruction']?.toString() ?? 'Extend',
      subtitle: pending
          ? (message != null && message.isNotEmpty
                ? message
                : 'Waiting to generate')
          : failed && error != null && error.isNotEmpty
          ? error
          : _when(request['created_at']?.toString()),
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (pending)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: request['progress_fraction'] is num
                    ? (request['progress_fraction'] as num).toDouble()
                    : 0.2,
                minHeight: 8,
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: onDelete,
              child: Text(
                'Delete',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
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

class _ClusterPill extends StatelessWidget {
  const _ClusterPill({
    required this.label,
    required this.width,
    required this.height,
    required this.onTap,
  });

  final ClusterLabel label;
  final double width;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final size = (height * 0.42).clamp(8.0, label.level <= 1 ? 15.0 : 13.0);
    final ink = label.color.computeLuminance() > 0.62
        ? const Color(0xFF1C2430)
        : Colors.white;
    return Material(
      color: label.color,
      elevation: label.level <= 1 ? 3 : 1,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(height),
      child: InkWell(
        borderRadius: BorderRadius.circular(height),
        onTap: onTap,
        child: SizedBox(
          width: width,
          height: height,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Center(
              child: Text(
                label.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: ink,
                  fontWeight: FontWeight.w700,
                  fontSize: size,
                  height: 1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HexPainter extends CustomPainter {
  const _HexPainter(this.hexes, this.shown);

  final List<ClusterHex> hexes;
  final int shown;

  @override
  void paint(Canvas canvas, Size size) {
    for (final hex in hexes) {
      final filled = hex.filledAt(shown);
      if (!filled && !hex.outlineAt(shown)) continue;
      final path = _hexPath(hex.cx, hex.cy, hex.radius * 0.94);
      canvas.drawPath(
        path,
        Paint()..color = filled ? hex.color : hex.color.withValues(alpha: 0.16),
      );
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.min(5, math.max(1.25, hex.radius * 0.028))
          ..color = const Color(
            0xFF0E1218,
          ).withValues(alpha: filled ? 0.5 : 0.28),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HexPainter oldDelegate) =>
      oldDelegate.shown != shown || oldDelegate.hexes != hexes;
}

Path _hexPath(double cx, double cy, double radius) {
  final path = Path();
  for (var corner = 0; corner < 6; corner++) {
    final angle = math.pi / 180 * (60 * corner - 30);
    final point = Offset(
      cx + radius * math.cos(angle),
      cy + radius * math.sin(angle),
    );
    if (corner == 0) {
      path.moveTo(point.dx, point.dy);
    } else {
      path.lineTo(point.dx, point.dy);
    }
  }
  path.close();
  return path;
}

class _NodeSheet extends StatefulWidget {
  const _NodeSheet({
    required this.node,
    required this.onExtend,
    required this.onDelete,
  });

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
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.node['title']?.toString() ?? 'Concept',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
          ),
          if (range.isNotEmpty) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.4,
              ),
              child: SingleChildScrollView(child: Text(range)),
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _instruction,
            decoration: const InputDecoration(
              labelText: 'Extend this node',
              filled: true,
            ),
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
            child: Text(
              'Delete node',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }
}
