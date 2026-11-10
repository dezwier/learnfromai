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
  var _resumed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _resumed) return;
      _resumed = true;
      context.read<GraphController>().resume();
    });
  }

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
          if (layout.related.isNotEmpty) _RelatedStrip(related: layout.related, onOpen: graph.openNode),
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

  Widget _body(BuildContext context, GraphController graph, HierarchyLayout layout) {
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
                (choice.description?.trim().isNotEmpty == true) ? choice.description! : 'Q${choice.id}',
              ),
              onTap: () => graph.choose(choice),
            ),
        ],
      );
    }
    if (layout.nodes.isEmpty) {
      return ListView(
        padding: studyPagePadding,
        children: const [
          StudyCard(
            eyebrow: 'GRAPH',
            title: 'Explore the graph',
            subtitle: 'Search a topic to see its parents, children, and related pages.',
          ),
        ],
      );
    }
    return _HierarchyView(
      layout: layout,
      focusId: graph.focusId,
      pendingId: graph.refreshing ? graph.pendingNodeId : null,
      transform: _transform,
      onOpen: graph.openNode,
    );
  }

  HierarchyLayout _layoutFor(GraphController graph) {
    final payload = graph.categoryGraph;
    if (payload == null) {
      return const HierarchyLayout(nodes: [], edges: [], related: [], width: 0, height: 0);
    }
    final nodes = [
      for (final raw in (payload['nodes'] as List?) ?? const [])
        if (raw is Map)
          GraphNode(
            id: (raw['id'] as num).toInt(),
            title: raw['title']?.toString() ?? '',
            depth: (raw['depth'] as num?)?.toInt() ?? 0,
            distance: (raw['distance'] as num?)?.toInt() ?? 0,
            kind: raw['kind']?.toString() ?? 'focus',
          ),
    ];
    final edges = [
      for (final raw in (payload['edges'] as List?) ?? const [])
        if (raw is Map)
          GraphEdge(
            source: (raw['source'] as num).toInt(),
            target: (raw['target'] as num).toInt(),
            type: raw['type']?.toString() ?? 'subclass_of',
          ),
    ];
    final focus = graph.focusId ?? (nodes.isEmpty ? 0 : nodes.first.id);
    return layoutHierarchy(nodes, edges, focusId: focus);
  }
}

class _RelatedStrip extends StatelessWidget {
  const _RelatedStrip({required this.related, required this.onOpen});

  final List<GraphNode> related;
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
      child: SizedBox(
        height: 64,
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          scrollDirection: Axis.horizontal,
          itemCount: related.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final node = related[index];
            return ActionChip(
              label: Text(node.title),
              onPressed: () => onOpen(node.id),
            );
          },
        ),
      ),
    );
  }
}

class _HierarchyView extends StatelessWidget {
  const _HierarchyView({
    required this.layout,
    required this.focusId,
    required this.pendingId,
    required this.transform,
    required this.onOpen,
  });

  final HierarchyLayout layout;
  final int? focusId;
  final int? pendingId;
  final TransformationController transform;
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: InteractiveViewer(
        transformationController: transform,
        constrained: false,
        minScale: 0.6,
        maxScale: 2.5,
        boundaryMargin: const EdgeInsets.all(160),
        child: SizedBox(
          width: layout.width < 320 ? 320 : layout.width,
          height: layout.height < 240 ? 240 : layout.height,
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _EdgePainter(layout: layout, color: scheme.primary),
                ),
              ),
              for (final node in layout.nodes)
                Positioned(
                  left: node.x,
                  top: node.y,
                  width: node.width,
                  height: node.height,
                  child: Material(
                    color: node.id == pendingId
                        ? scheme.primary.withValues(alpha: 0.12)
                        : scheme.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: scheme.primary,
                        width: node.id == focusId ? 2.4 : 1.4,
                      ),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => onOpen(node.id),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            node.title,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.15,
                              fontWeight: node.id == focusId ? FontWeight.w700 : FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EdgePainter extends CustomPainter {
  _EdgePainter({required this.layout, required this.color});

  final HierarchyLayout layout;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final byId = {for (final node in layout.nodes) node.id: node};
    final line = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    for (final edge in layout.edges) {
      final from = byId[edge.source];
      final to = byId[edge.target];
      if (from == null || to == null) continue;
      canvas.drawLine(
        Offset(from.x + from.width / 2, from.y + from.height),
        Offset(to.x + to.width / 2, to.y),
        line,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _EdgePainter oldDelegate) {
    return oldDelegate.layout != layout || oldDelegate.color != color;
  }
}
