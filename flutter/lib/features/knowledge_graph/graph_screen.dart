import 'dart:math' as math;

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
  final _search = TextEditingController();
  final _transform = TransformationController();
  int? _focusedFor;

  @override
  void dispose() {
    _search.dispose();
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final graph = context.watch<GraphController>();
    _resetView(graph);
    final layout = _layoutFor(graph);
    return Scaffold(
      appBar: GradientTopBar(
        title: 'Graph',
        actions: [
          if (graph.canGoBack)
            IconButton(
              tooltip: 'Previous topic',
              onPressed: () => graph.back(),
              icon: const Icon(Icons.arrow_back),
            ),
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
            tooltip: 'Sign out',
            onPressed: () => context.read<AuthController>().signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _search,
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(hintText: 'Search a topic', isDense: true),
                    onSubmitted: graph.search,
                  ),
                ),
                IconButton(
                  tooltip: 'Search',
                  onPressed: () => graph.search(_search.text),
                  icon: const Icon(Icons.search),
                ),
              ],
            ),
          ),
          if (graph.categoryGraph?['incomplete'] == true)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text('Some surrounding topics are still loading. Open this topic again to continue.'),
            ),
          if (graph.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: StudyCard(dense: true, eyebrow: 'GRAPH', title: graph.error!, subtitle: 'Try another topic.'),
            ),
          Expanded(child: _body(context, graph, layout)),
        ],
      ),
    );
  }

  void _resetView(GraphController graph) {
    final focus = graph.focusId;
    if (_focusedFor == focus) return;
    _focusedFor = focus;
    _transform.value = Matrix4.identity();
  }

  Widget _body(BuildContext context, GraphController graph, HexLayout layout) {
    if (graph.loading && graph.categoryGraph == null) {
      return const Padding(padding: studyPagePadding, child: PulsePlaceholder.map());
    }
    if (graph.candidates.isNotEmpty) {
      return ListView(
        padding: studyPagePadding,
        children: [
          const StudyCard(
            eyebrow: 'TOPICS',
            title: 'Choose a topic',
            subtitle: 'More than one Wikidata item matches this search.',
          ),
          const SizedBox(height: 12),
          for (final choice in graph.candidates)
            ListTile(
              title: Text(choice.title),
              subtitle: Text(
                (choice.description?.trim().isNotEmpty == true)
                    ? choice.description!
                    : 'Q${choice.id}',
              ),
              onTap: () => graph.choose(choice),
            ),
        ],
      );
    }
    if (layout.cells.isEmpty) {
      return ListView(
        padding: studyPagePadding,
        children: const [
          StudyCard(
            eyebrow: 'GRAPH',
            title: 'Explore the graph',
            subtitle: 'Parents merge into a hex. Zoom in to split it into children.',
          ),
        ],
      );
    }
    return _HexView(
      layout: layout,
      focusId: graph.focusId,
      pendingId: graph.refreshing ? graph.pendingNodeId : null,
      transform: _transform,
      onScale: () => setState(() {}),
      onOpen: graph.openCategory,
    );
  }

  HexLayout _layoutFor(GraphController graph) {
    final payload = graph.categoryGraph;
    if (payload == null) {
      return const HexLayout(cells: [], width: 0, height: 0);
    }
    final nodes = [
      for (final raw in (payload['nodes'] as List?) ?? const [])
        if (raw is Map)
          GraphNode(
            id: (raw['id'] as num).toInt(),
            title: raw['title']?.toString() ?? '',
            depth: (raw['depth'] as num?)?.toInt() ?? 0,
            distance: (raw['distance'] as num?)?.toInt() ?? 0,
          ),
    ];
    final edges = [
      for (final raw in (payload['edges'] as List?) ?? const [])
        if (raw is Map)
          GraphEdge(source: (raw['source'] as num).toInt(), target: (raw['target'] as num).toInt()),
    ];
    final scale = _transform.value.getMaxScaleOnAxis();
    return layoutHexMap(nodes, edges, focusId: graph.focusId ?? 0, scale: scale);
  }
}

class _HexView extends StatelessWidget {
  const _HexView({
    required this.layout,
    required this.focusId,
    required this.pendingId,
    required this.transform,
    required this.onScale,
    required this.onOpen,
  });

  final HexLayout layout;
  final int? focusId;
  final int? pendingId;
  final TransformationController transform;
  final VoidCallback onScale;
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scale = transform.value.getMaxScaleOnAxis();
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: InteractiveViewer(
        transformationController: transform,
        constrained: false,
        minScale: 0.4,
        maxScale: 3.2,
        boundaryMargin: const EdgeInsets.all(240),
        onInteractionUpdate: (_) => onScale(),
        onInteractionEnd: (_) => onScale(),
        child: SizedBox(
          width: layout.width < 320 ? 320 : layout.width,
          height: layout.height < 240 ? 240 : layout.height,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) {
              final id = hitTestHex(layout, details.localPosition);
              if (id != null) onOpen(id);
            },
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _HexPainter(layout: layout, focusId: focusId, color: scheme.primary, fill: scheme.surface),
                  ),
                ),
                for (final cell in layout.cells)
                  if (cell.showLabel)
                    Positioned(
                      left: cell.x,
                      top: cell.y,
                      child: Transform.translate(
                        offset: Offset(-80, -hexLabelFontSize),
                        child: Transform.scale(
                          scale: 1 / scale,
                          child: SizedBox(
                            width: 160,
                            child: Text(
                              cell.title,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: hexLabelFontSize,
                                height: 1.1,
                                fontWeight: cell.id == focusId ? FontWeight.w700 : FontWeight.w500,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                if (pendingId != null)
                  const Positioned(
                    right: 16,
                    top: 16,
                    child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HexPainter extends CustomPainter {
  _HexPainter({required this.layout, required this.focusId, required this.color, required this.fill});

  final HexLayout layout;
  final int? focusId;
  final Color color;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final border = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final selected = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4;
    final background = Paint()
      ..color = fill
      ..style = PaintingStyle.fill;
    for (final cell in layout.cells) {
      final path = _hex(Offset(cell.x, cell.y), cell.radius);
      canvas.drawPath(path, background);
      canvas.drawPath(path, cell.id == focusId ? selected : border);
    }
  }

  Path _hex(Offset center, double radius) {
    final path = Path();
    for (var index = 0; index < 6; index++) {
      final angle = math.pi / 180 * (60 * index - 30);
      final point = Offset(center.dx + radius * math.cos(angle), center.dy + radius * math.sin(angle));
      if (index == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(covariant _HexPainter oldDelegate) {
    return oldDelegate.layout.cells != layout.cells || oldDelegate.focusId != focusId || oldDelegate.color != color;
  }
}
