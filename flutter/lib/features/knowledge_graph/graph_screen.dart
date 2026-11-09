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
  final _expanded = <int>{};
  int? _expandedFor;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final graph = context.watch<GraphController>();
    final focus = graph.focusId;
    if (_expandedFor != focus) {
      _expandedFor = focus;
      _expanded.clear();
    }
    final layout = _layoutFor(graph);
    return Scaffold(
      appBar: GradientTopBar(
        title: 'Graph',
        actions: [
          if (graph.canGoBack)
            IconButton(
              tooltip: 'Previous category',
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
              child: Text('Some surrounding categories are still loading. Open this topic again to continue.'),
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

  Widget _body(BuildContext context, GraphController graph, HierarchyLayout layout) {
    if (graph.loading && graph.categoryGraph == null) {
      return const Padding(padding: studyPagePadding, child: PulsePlaceholder());
    }
    if (graph.candidates.isNotEmpty) {
      return ListView(
        padding: studyPagePadding,
        children: [
          const StudyCard(
            eyebrow: 'CATEGORIES',
            title: 'Choose a category',
            subtitle: 'More than one Wikipedia category matches this search.',
          ),
          const SizedBox(height: 12),
          for (final choice in graph.candidates)
            ListTile(
              title: Text(choice.title),
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
            title: 'Search a Wikipedia category',
            subtitle: 'Parents sit above the category you choose. Subcategories sit below it.',
          ),
        ],
      );
    }
    return _HierarchyView(
      layout: layout,
      focusId: graph.focusId,
      pendingId: graph.refreshing ? graph.pendingNodeId : null,
      onOpen: graph.openCategory,
      onShowMore: (parentId) => setState(() => _expanded.add(parentId)),
    );
  }

  HierarchyLayout _layoutFor(GraphController graph) {
    final payload = graph.categoryGraph;
    if (payload == null) {
      return const HierarchyLayout(nodes: [], edges: [], anchors: [], width: 0, height: 0);
    }
    final nodes = [
      for (final raw in (payload['nodes'] as List?) ?? const [])
        if (raw is Map)
          HierarchyNode(
            id: (raw['id'] as num).toInt(),
            title: raw['title']?.toString() ?? '',
            depth: (raw['depth'] as num?)?.toInt() ?? 0,
          ),
    ];
    final edges = [
      for (final raw in (payload['edges'] as List?) ?? const [])
        if (raw is Map)
          HierarchyEdge(source: (raw['source'] as num).toInt(), target: (raw['target'] as num).toInt()),
    ];
    return layoutHierarchy(nodes, edges, expanded: _expanded);
  }
}

class _HierarchyView extends StatelessWidget {
  const _HierarchyView({
    required this.layout,
    required this.focusId,
    required this.pendingId,
    required this.onOpen,
    required this.onShowMore,
  });

  final HierarchyLayout layout;
  final int? focusId;
  final int? pendingId;
  final ValueChanged<int> onOpen;
  final ValueChanged<int> onShowMore;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final line = ink.withValues(alpha: 0.28);
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: InteractiveViewer(
        constrained: false,
        minScale: 0.4,
        maxScale: 2.5,
        boundaryMargin: const EdgeInsets.all(240),
        child: SizedBox(
          width: layout.width < 320 ? 320 : layout.width,
          height: layout.height < 240 ? 240 : layout.height,
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(painter: _EdgePainter(layout: layout, color: line)),
              ),
              for (final node in layout.nodes)
                AnimatedPositioned(
                  key: ValueKey('category-${node.id}'),
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  left: node.dx,
                  top: node.dy,
                  width: hierarchyNodeWidth,
                  height: hierarchyNodeHeight,
                  child: _CategoryNode(
                    title: node.title,
                    selected: node.id == focusId,
                    pending: node.id == pendingId,
                    onTap: () => onOpen(node.id),
                  ),
                ),
              for (final anchor in layout.anchors)
                Positioned(
                  left: anchor.dx,
                  top: anchor.dy,
                  width: 80,
                  height: 32,
                  child: TextButton(
                    onPressed: () => onShowMore(anchor.parentId),
                    child: const Text('Show more'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryNode extends StatelessWidget {
  const _CategoryNode({required this.title, required this.selected, required this.pending, required this.onTap});

  final String title;
  final bool selected;
  final bool pending;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = selected ? scheme.primary : scheme.surface;
    final foreground = selected ? scheme.onPrimary : scheme.onSurface;
    return Material(
      color: background,
      elevation: selected ? 2 : 0,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? scheme.primary : scheme.onSurface.withValues(alpha: 0.16)),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: foreground, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, height: 1.2),
              ),
              if (pending)
                const Align(
                  alignment: Alignment.topRight,
                  child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
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
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final byId = {for (final node in layout.nodes) node.id: node};
    for (final edge in layout.edges) {
      final parent = byId[edge.source];
      final child = byId[edge.target];
      if (parent == null || child == null) continue;
      canvas.drawLine(
        Offset(parent.dx + hierarchyNodeWidth / 2, parent.dy + hierarchyNodeHeight),
        Offset(child.dx + hierarchyNodeWidth / 2, child.dy),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _EdgePainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.layout.nodes != layout.nodes || oldDelegate.layout.edges != layout.edges;
  }
}
