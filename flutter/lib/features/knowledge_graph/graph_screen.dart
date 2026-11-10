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
  final _searchFocus = FocusNode();
  final _transform = TransformationController();
  int? _focusedFor;
  var _resumed = false;
  var _searchOpen = false;

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
    _searchFocus.dispose();
    _transform.dispose();
    super.dispose();
  }

  void _openSearch() {
    if (_searchOpen) return;
    setState(() => _searchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _searchFocus.requestFocus();
    });
  }

  void _dismissSearch() {
    if (!_searchOpen && !_searchFocus.hasFocus) return;
    _searchFocus.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    if (_searchOpen) setState(() => _searchOpen = false);
  }

  Future<void> _submitSearch(GraphController graph) async {
    final topic = _search.text;
    _dismissSearch();
    await graph.search(topic);
  }

  @override
  Widget build(BuildContext context) {
    final graph = context.watch<GraphController>();
    _resetView(graph);
    final layout = _layoutFor(graph);
    return Scaffold(
      resizeToAvoidBottomInset: true,
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
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _dismissSearch,
        child: Stack(
          children: [
            Column(
              children: [
                if (graph.categoryGraph?['incomplete'] == true)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 8, 20, 4),
                    child: Text(
                      'Some surrounding topics are still loading. Open this topic again to continue.',
                    ),
                  ),
                if (graph.error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: StudyCard(
                      dense: true,
                      eyebrow: 'GRAPH',
                      title: graph.error!,
                      subtitle: 'Try another topic.',
                    ),
                  ),
                if (layout.nodes.isNotEmpty) const _Legend(),
                Expanded(child: _body(context, graph, layout)),
              ],
            ),
            Positioned(
              right: 16,
              bottom: 16 + MediaQuery.viewInsetsOf(context).bottom,
              child: _FloatingSearch(
                open: _searchOpen,
                controller: _search,
                focusNode: _searchFocus,
                onOpen: _openSearch,
                onSubmit: () => _submitSearch(graph),
                onDismiss: _dismissSearch,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _resetView(GraphController graph) {
    final focus = graph.focusId;
    if (_focusedFor == focus) return;
    _focusedFor = focus;
    _transform.value = Matrix4.identity();
  }

  Widget _body(BuildContext context, GraphController graph, GraphLayout layout) {
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
            subtitle: 'Search a topic to see parents above, children below, and related neighbors on the sides.',
          ),
        ],
      );
    }
    return _GraphView(
      layout: layout,
      focusId: graph.focusId,
      pendingId: graph.refreshing ? graph.pendingNodeId : null,
      transform: _transform,
      onOpen: graph.openNode,
    );
  }

  GraphLayout _layoutFor(GraphController graph) {
    final payload = graph.categoryGraph;
    if (payload == null) {
      return const GraphLayout(nodes: [], edges: [], width: 0, height: 0);
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
    return layoutGraph(nodes, edges, focusId: focus);
  }
}

class _FloatingSearch extends StatelessWidget {
  const _FloatingSearch({
    required this.open,
    required this.controller,
    required this.focusNode,
    required this.onOpen,
    required this.onSubmit,
    required this.onDismiss,
  });

  final bool open;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onOpen;
  final VoidCallback onSubmit;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!open) {
      return FloatingActionButton(
        heroTag: 'graph-search',
        tooltip: 'Search',
        onPressed: onOpen,
        child: const Icon(Icons.search),
      );
    }
    return Material(
      elevation: 6,
      color: scheme.surface,
      borderRadius: BorderRadius.circular(28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 220, maxWidth: 320),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 16),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: 'Search a topic',
                  border: InputBorder.none,
                  isDense: true,
                ),
                onSubmitted: (_) => onSubmit(),
                onTapOutside: (_) => onDismiss(),
              ),
            ),
            IconButton(
              tooltip: 'Search',
              onPressed: onSubmit,
              icon: const Icon(Icons.search),
            ),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 6,
        children: [
          _LegendSwatch(color: roleColor(NodeRole.parent, scheme), label: 'Parent'),
          _LegendSwatch(color: roleColor(NodeRole.focus, scheme), label: 'Focus'),
          _LegendSwatch(color: roleColor(NodeRole.child, scheme), label: 'Child'),
          _LegendSwatch(color: roleColor(NodeRole.related, scheme), label: 'Related'),
        ],
      ),
    );
  }
}

class _LegendSwatch extends StatelessWidget {
  const _LegendSwatch({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.labelMedium),
      ],
    );
  }
}

class _GraphView extends StatelessWidget {
  const _GraphView({
    required this.layout,
    required this.focusId,
    required this.pendingId,
    required this.transform,
    required this.onOpen,
  });

  final GraphLayout layout;
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
        minScale: 0.25,
        maxScale: 3.0,
        boundaryMargin: const EdgeInsets.all(400),
        child: SizedBox(
          width: layout.width < 360 ? 360 : layout.width,
          height: layout.height < 280 ? 280 : layout.height,
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _EdgePainter(layout: layout, scheme: scheme),
                ),
              ),
              for (final node in layout.nodes)
                Positioned(
                  left: node.x,
                  top: node.y,
                  width: node.width,
                  height: node.height,
                  child: _NodeCard(
                    node: node,
                    focused: node.id == focusId,
                    pending: node.id == pendingId,
                    onTap: () => onOpen(node.id),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NodeCard extends StatelessWidget {
  const _NodeCard({
    required this.node,
    required this.focused,
    required this.pending,
    required this.onTap,
  });

  final PlacedNode node;
  final bool focused;
  final bool pending;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = roleColor(node.role, scheme);
    return Material(
      color: pending ? accent.withValues(alpha: 0.14) : scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: accent, width: focused ? 2.6 : 1.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                node.title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.15,
                  fontWeight: focused ? FontWeight.w700 : FontWeight.w500,
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
  _EdgePainter({required this.layout, required this.scheme});

  final GraphLayout layout;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    final byId = {for (final node in layout.nodes) node.id: node};
    for (final edge in layout.edges) {
      final from = byId[edge.source];
      final to = byId[edge.target];
      if (from == null || to == null) continue;
      final paint = Paint()
        ..color = edgeColor(edge, scheme)
        ..strokeWidth = edge.isRelated ? 1.2 : 1.8
        ..style = PaintingStyle.stroke;
      if (edge.isRelated) {
        paint.strokeCap = StrokeCap.round;
        _drawCurve(canvas, from.center, to.center, paint);
      } else {
        canvas.drawLine(
          Offset(from.x + from.width / 2, from.y + from.height),
          Offset(to.x + to.width / 2, to.y),
          paint,
        );
      }
    }
  }

  void _drawCurve(Canvas canvas, Offset a, Offset b, Paint paint) {
    final path = Path()
      ..moveTo(a.dx, a.dy)
      ..quadraticBezierTo((a.dx + b.dx) / 2, (a.dy + b.dy) / 2 - 24, b.dx, b.dy);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _EdgePainter oldDelegate) {
    return oldDelegate.layout != layout || oldDelegate.scheme != scheme;
  }
}
