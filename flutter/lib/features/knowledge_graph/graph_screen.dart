import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/pulse_placeholder.dart';
import '../../core/widgets/study_card.dart';
import '../profile/profile_hud.dart';
import '../profile/profile_screen.dart';
import 'graph_controller.dart';
import 'graph_layout.dart';
import 'title_wrap.dart';

class GraphScreen extends StatefulWidget {
  const GraphScreen({super.key});

  @override
  State<GraphScreen> createState() => _GraphScreenState();
}

class _GraphScreenState extends State<GraphScreen> with SingleTickerProviderStateMixin {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _transform = TransformationController();
  late final AnimationController _panController;
  Animation<Matrix4>? _panAnimation;
  String? _transformFocusId;
  /// While set, ignore center-highlight updates that aren't this id (avoids drawer flicker mid-pan).
  String? _panTargetId;
  Timer? _suggestDebounce;
  Offset? _searchOutsideDown;
  var _searchOutsideMoved = false;
  var _resumed = false;
  var _searchOpen = false;
  var _profileOpen = false;
  var _drawerRaised = false;
  PlacedNode? _highlighted;
  Size _viewport = Size.zero;

  @override
  void initState() {
    super.initState();
    _panController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    )..addListener(_onPanTick);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _resumed) return;
      _resumed = true;
      context.read<GraphController>().resume();
    });
  }

  @override
  void dispose() {
    _suggestDebounce?.cancel();
    _panController
      ..removeListener(_onPanTick)
      ..dispose();
    _search.dispose();
    _searchFocus.dispose();
    _transform.dispose();
    super.dispose();
  }

  void _onPanTick() {
    final anim = _panAnimation;
    if (anim == null) return;
    _transform.value = anim.value;
  }

  void _resetTransformIfFocusChanged({
    required String? focusId,
    required Size viewport,
    required Size canvas,
  }) {
    if (_transformFocusId == focusId) return;
    _transformFocusId = focusId;
    _panController.stop();
    _panAnimation = null;
    _panTargetId = null;
    // Focus is laid out at the canvas center; translate so that lands in view.
    _transform.value = Matrix4.translationValues(
      (viewport.width - canvas.width) / 2,
      (viewport.height - canvas.height) / 2,
      0,
    );
  }

  Matrix4 _matrixCentering(Offset scenePoint, Size viewport, {required double scale}) {
    return Matrix4.identity()
      ..translateByDouble(viewport.width / 2, viewport.height / 2, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1)
      ..translateByDouble(-scenePoint.dx, -scenePoint.dy, 0, 1);
  }

  Future<void> _animatePanTo(Offset scenePoint, Size viewport) async {
    if (viewport.isEmpty) return;
    final scale = _transform.value.getMaxScaleOnAxis();
    final begin = _transform.value.clone();
    final end = _matrixCentering(scenePoint, viewport, scale: scale);
    _panController.stop();
    _panAnimation = Matrix4Tween(begin: begin, end: end).animate(
      CurvedAnimation(parent: _panController, curve: Curves.easeInOutCubic),
    );
    await _panController.forward(from: 0);
    if (!mounted) return;
    _panTargetId = null;
    _panAnimation = null;
  }

  void _selectNode(PlacedNode node) {
    _panTargetId = node.id;
    if (_highlighted?.id != node.id ||
        _highlighted?.title != node.title ||
        _highlighted?.description != node.description) {
      setState(() {
        if (_highlighted?.id != node.id) _drawerRaised = false;
        _highlighted = node;
      });
    }
    unawaited(_animatePanTo(node.center, _viewport));
  }

  void _onHighlightFromCenter(PlacedNode? node) {
    if (!mounted) return;
    final pin = _panTargetId;
    if (pin != null && node?.id != pin) return;
    if (pin != null && node?.id == pin) {
      _panTargetId = null;
    }
    if (node?.id == _highlighted?.id &&
        node?.title == _highlighted?.title &&
        node?.description == _highlighted?.description) {
      return;
    }
    setState(() {
      if (_highlighted?.id != node?.id) _drawerRaised = false;
      _highlighted = node;
    });
  }

  Future<void> _goToHighlighted(GraphController graph) async {
    final node = _highlighted;
    if (node == null || node.id == graph.focusId) return;
    await graph.openNode(node.id);
  }

  Future<void> _editHighlighted(GraphController graph) async {
    final node = _highlighted;
    if (node == null) return;
    final titleCtrl = TextEditingController(text: node.title);
    final descCtrl = TextEditingController(text: (node.description ?? '').trim());
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Edit topic'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(labelText: 'Title'),
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descCtrl,
                  decoration: const InputDecoration(labelText: 'Description'),
                  minLines: 4,
                  maxLines: 10,
                  textCapitalization: TextCapitalization.sentences,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ],
        );
      },
    );
    final title = titleCtrl.text.trim();
    final description = descCtrl.text.trim();
    titleCtrl.dispose();
    descCtrl.dispose();
    if (saved != true || !mounted || title.isEmpty) return;
    final ok = await graph.updateNode(id: node.id, title: title, description: description);
    if (!ok || !mounted) return;
    setState(() {
      _highlighted = PlacedNode(
        id: node.id,
        title: title,
        depth: node.depth,
        distance: node.distance,
        kind: node.kind,
        role: node.role,
        x: node.x,
        y: node.y,
        width: node.width,
        height: node.height,
        radius: node.radius,
        isFlower: node.isFlower,
        description: description,
        viaRole: node.viaRole,
      );
    });
  }

  Future<void> _confirmDeleteHighlighted(GraphController graph) async {
    final node = _highlighted;
    if (node == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete topic?'),
          content: Text(
            'Delete “${node.title}” and all of its edges from the shared graph? This cannot be undone.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    final ok = await graph.deleteNode(node.id);
    if (!ok || !mounted) return;
    setState(() {
      _highlighted = null;
      _drawerRaised = false;
    });
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
    _suggestDebounce?.cancel();
    if (!_searchOpen && !_searchFocus.hasFocus) return;
    _searchFocus.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    context.read<GraphController>().clearSuggestions();
    if (_searchOpen) setState(() => _searchOpen = false);
  }

  void _onSearchChanged(GraphController graph, String value) {
    _suggestDebounce?.cancel();
    _suggestDebounce = Timer(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      graph.suggest(value);
    });
  }

  Future<void> _submitSearch(GraphController graph) async {
    final topic = _search.text.trim();
    if (topic.isEmpty) return;
    // Prefer an exact existing match when the user submits without picking.
    TopicChoice? exact;
    for (final choice in graph.suggestions) {
      if (choice.title.toLowerCase() == topic.toLowerCase()) {
        exact = choice;
        break;
      }
    }
    _search.clear();
    _dismissSearch();
    if (exact != null) {
      await graph.openExisting(exact.id);
    } else {
      await graph.search(topic);
    }
  }

  Future<void> _pickSuggestion(GraphController graph, TopicChoice choice) async {
    _search.clear();
    _dismissSearch();
    await graph.openExisting(choice.id);
  }

  void _openProfile() {
    _dismissSearch();
    setState(() => _profileOpen = true);
  }

  void _closeProfile() {
    if (!_profileOpen) return;
    setState(() => _profileOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    final graph = context.watch<GraphController>();
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final scheme = Theme.of(context).colorScheme;
    final drawerVisible = !_profileOpen && !_searchOpen && _highlighted != null;
    final drawerClearance =
        drawerVisible ? _HighlightDrawer.collapsedHeight(safeBottom) + 12 : 16.0;
    final floatBottom = drawerClearance + keyboard;
    final canGoToHighlight =
        !_searchOpen && !_profileOpen && _highlighted != null && _highlighted!.id != graph.focusId;
    final showFloats = !_searchOpen && !_profileOpen && !_drawerRaised;
    return Scaffold(
      // Keep the graph still when the keyboard opens; search floats above it.
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Column(
            children: [
              if (graph.categoryGraph?['incomplete'] == true)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 8, 20, 4),
                  child: Text('Some surrounding topics are still loading. Open this topic again to continue.'),
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
              Expanded(
                child: _searchOpen
                    ? Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerDown: (event) {
                          _searchOutsideDown = event.position;
                          _searchOutsideMoved = false;
                        },
                        onPointerMove: (event) {
                          final start = _searchOutsideDown;
                          if (start == null || _searchOutsideMoved) return;
                          // Treat as pan once the finger moves past a tap slop.
                          if ((event.position - start).distanceSquared > 64) {
                            _searchOutsideMoved = true;
                          }
                        },
                        onPointerUp: (_) {
                          final wasTap = !_searchOutsideMoved && _searchOutsideDown != null;
                          _searchOutsideDown = null;
                          _searchOutsideMoved = false;
                          if (wasTap) _dismissSearch();
                        },
                        onPointerCancel: (_) {
                          _searchOutsideDown = null;
                          _searchOutsideMoved = false;
                        },
                        child: _body(context, graph),
                      )
                    : _body(context, graph),
              ),
            ],
          ),
          if (!_profileOpen) const ProfileTopFade(),
          if (!_profileOpen)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ProfileHud(onTap: _openProfile),
                  ),
                ),
              ),
            ),
          if (drawerVisible)
            Align(
              alignment: Alignment.bottomCenter,
              child: _HighlightDrawer(
                key: ValueKey(_highlighted!.id),
                node: _highlighted!,
                canViewInGraph: canGoToHighlight,
                onRaisedChanged: (raised) {
                  if (_drawerRaised == raised) return;
                  setState(() => _drawerRaised = raised);
                },
                onViewInGraph: () => _goToHighlighted(graph),
                onEdit: () => _editHighlighted(graph),
                onDelete: () => _confirmDeleteHighlighted(graph),
              ),
            ),
          if (graph.working && showFloats)
            Positioned(
              left: 16,
              bottom: floatBottom,
              child: _ProgressChip(message: graph.progressMessage ?? 'Working…'),
            ),
          if (showFloats)
            Positioned(
              right: 16,
              bottom: floatBottom,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (canGoToHighlight) ...[
                    FloatingActionButton.small(
                      heroTag: 'graph-go',
                      tooltip: 'Go to topic',
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                      elevation: 1.5,
                      focusElevation: 2,
                      hoverElevation: 2,
                      highlightElevation: 2,
                      onPressed: graph.working ? null : () => _goToHighlighted(graph),
                      child: const Icon(Icons.arrow_forward, size: 20),
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (graph.canGoBack) ...[
                    FloatingActionButton.small(
                      heroTag: 'graph-back',
                      tooltip: 'Previous topic',
                      backgroundColor: scheme.surfaceContainerHighest,
                      foregroundColor: scheme.onSurfaceVariant,
                      elevation: 1.5,
                      focusElevation: 2,
                      hoverElevation: 2,
                      highlightElevation: 2,
                      onPressed: () => graph.back(),
                      child: const Icon(Icons.arrow_back, size: 20),
                    ),
                    const SizedBox(height: 10),
                  ],
                  FloatingActionButton.small(
                    heroTag: 'graph-search',
                    tooltip: 'Search',
                    backgroundColor: scheme.surfaceContainerHighest,
                    foregroundColor: scheme.onSurfaceVariant,
                    elevation: 1.5,
                    focusElevation: 2,
                    hoverElevation: 2,
                    highlightElevation: 2,
                    onPressed: _openSearch,
                    child: const Icon(Icons.search, size: 20),
                  ),
                ],
              ),
            ),
          if (_searchOpen)
            Positioned(
              left: 0,
              right: 0,
              bottom: keyboard,
              child: _SearchBar(
                controller: _search,
                focusNode: _searchFocus,
                suggestions: graph.suggestions,
                onChanged: (value) => _onSearchChanged(graph, value),
                onSubmit: () => _submitSearch(graph),
                onPick: (choice) => _pickSuggestion(graph, choice),
              ),
            ),
          if (_profileOpen)
            Positioned.fill(
              child: ProfileScreen(onClose: _closeProfile),
            ),
        ],
      ),
    );
  }

  bool _hasNodes(GraphController graph) {
    final nodes = graph.categoryGraph?['nodes'];
    return nodes is List && nodes.isNotEmpty;
  }

  Widget _body(BuildContext context, GraphController graph) {
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
            subtitle: 'More than one topic matches this search.',
          ),
          const SizedBox(height: 12),
          for (final choice in graph.candidates)
            ListTile(
              title: Text(choice.title),
              subtitle: Text(
                (choice.description?.trim().isNotEmpty == true) ? choice.description! : choice.id,
              ),
              onTap: () => graph.choose(choice),
            ),
        ],
      );
    }
    if (!_hasNodes(graph)) {
      return ListView(
        padding: studyPagePadding,
        children: const [
          StudyCard(
            eyebrow: 'GRAPH',
            title: 'Explore the graph',
            subtitle: 'Search a topic to see parents, siblings, children, and related neighbors.',
          ),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        _viewport = viewport;
        final layout = _layoutFor(graph, viewport);
        _resetTransformIfFocusChanged(
          focusId: graph.focusId,
          viewport: viewport,
          canvas: Size(layout.width, layout.height),
        );
        // Generous margins so zoomed-out pan is free on both axes (portrait
        // viewports otherwise clamp vertical travel much harder than horizontal).
        final panSlack = math.max(viewport.width, viewport.height);
        return InteractiveViewer(
          transformationController: _transform,
          constrained: false,
          minScale: 0.45,
          maxScale: 3.5,
          boundaryMargin: EdgeInsets.symmetric(
            horizontal: panSlack,
            vertical: panSlack,
          ),
          onInteractionStart: (_) {
            if (!_panController.isAnimating) return;
            _panController.stop();
            _panAnimation = null;
            _panTargetId = null;
          },
          child: SizedBox(
            width: layout.width,
            height: layout.height,
            child: _GraphView(
              layout: layout,
              focusId: graph.focusId,
              highlightId: _highlighted?.id,
              pendingId: graph.refreshing ? graph.pendingNodeId : null,
              transform: _transform,
              viewport: viewport,
              onSelect: _selectNode,
              onHighlight: _onHighlightFromCenter,
            ),
          ),
        );
      },
    );
  }

  GraphLayout _layoutFor(GraphController graph, Size viewport) {
    final payload = graph.categoryGraph;
    if (payload == null) {
      return GraphLayout(nodes: const [], width: viewport.width, height: viewport.height);
    }
    final nodes = [
      for (final raw in (payload['nodes'] as List?) ?? const [])
        if (raw is Map)
          GraphNode(
            id: raw['id'].toString(),
            title: raw['title']?.toString() ?? '',
            depth: (raw['depth'] as num?)?.toInt() ?? 0,
            distance: (raw['distance'] as num?)?.toInt() ?? 0,
            kind: raw['kind']?.toString() ?? 'focus',
            description: raw['description']?.toString(),
          ),
    ];
    final edges = [
      for (final raw in (payload['edges'] as List?) ?? const [])
        if (raw is Map)
          GraphEdge(
            source: raw['source'].toString(),
            target: raw['target'].toString(),
            type: raw['type']?.toString() ?? 'child',
          ),
    ];
    final focus = graph.focusId ?? (nodes.isEmpty ? '' : nodes.first.id);
    return layoutGraph(
      nodes,
      edges,
      focusId: focus,
      viewport: viewport,
      maxExtended: graph.prefs.extended,
    );
  }
}

class _ProgressChip extends StatelessWidget {
  const _ProgressChip({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 3,
      color: scheme.surface.withValues(alpha: 0.94),
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.primary.withValues(alpha: 0.8),
              ),
            ),
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HighlightDrawer extends StatefulWidget {
  const _HighlightDrawer({
    super.key,
    required this.node,
    required this.canViewInGraph,
    required this.onRaisedChanged,
    required this.onViewInGraph,
    required this.onEdit,
    required this.onDelete,
  });

  /// Collapsed content height (above the home-indicator inset).
  static const double contentHeight = 168;

  static double collapsedHeight(double safeBottom) => contentHeight + safeBottom;

  final PlacedNode node;
  final bool canViewInGraph;
  final ValueChanged<bool> onRaisedChanged;
  final VoidCallback onViewInGraph;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  State<_HighlightDrawer> createState() => _HighlightDrawerState();
}

class _HighlightDrawerState extends State<_HighlightDrawer>
    with SingleTickerProviderStateMixin {
  /// 0 = collapsed, 1 = fully expanded (90% of screen).
  late final AnimationController _extent;
  final _bodyScroll = ScrollController();
  var _reportedRaised = false;

  bool get _expanded => _extent.value > 0.5;
  bool get _fullyOpen => _extent.value > 0.98;

  @override
  void initState() {
    super.initState();
    _extent = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
      value: 0,
    )..addListener(_onExtentTick);
  }

  @override
  void dispose() {
    _extent.removeListener(_onExtentTick);
    _extent.dispose();
    _bodyScroll.dispose();
    super.dispose();
  }

  void _onExtentTick() {
    if (!mounted) return;
    setState(() {});
    final raised = _extent.value > 0.08;
    if (raised == _reportedRaised) return;
    _reportedRaised = raised;
    widget.onRaisedChanged(raised);
  }

  double _collapsedPx(BuildContext context) {
    return _HighlightDrawer.collapsedHeight(MediaQuery.paddingOf(context).bottom);
  }

  double _expandedPx(BuildContext context) {
    return MediaQuery.sizeOf(context).height * 0.90;
  }

  double _heightFor(BuildContext context, double t) {
    final collapsed = _collapsedPx(context);
    final expanded = _expandedPx(context);
    return collapsed + (expanded - collapsed) * t.clamp(0.0, 1.0);
  }

  void _applyDragDy(double dy) {
    final range = _expandedPx(context) - _collapsedPx(context);
    if (range <= 0) return;
    _extent.value = (_extent.value - dy / range).clamp(0.0, 1.0);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final dy = details.delta.dy;
    if (dy > 0) {
      // Finger down: always drag the drawer down (collapse), never scroll content.
      if (_bodyScroll.hasClients && _bodyScroll.offset > 0) {
        _bodyScroll.jumpTo(0);
      }
      _applyDragDy(dy);
      return;
    }
    // Finger up: scroll content when fully open, otherwise expand the drawer.
    if (_fullyOpen && _bodyScroll.hasClients) {
      final max = _bodyScroll.position.maxScrollExtent;
      if (_bodyScroll.offset < max) {
        _bodyScroll.jumpTo((_bodyScroll.offset - dy).clamp(0.0, max));
        return;
      }
    }
    _applyDragDy(dy);
  }

  void _snap({double velocity = 0}) {
    final open = velocity < -400 || (velocity <= 400 && _extent.value >= 0.35);
    _extent.animateTo(open ? 1 : 0, curve: Curves.easeOutCubic);
  }

  void _onDragEnd(DragEndDetails details) {
    _snap(velocity: details.primaryVelocity ?? 0);
  }

  void _toggle() {
    if (_bodyScroll.hasClients && _bodyScroll.offset > 0) {
      _bodyScroll.jumpTo(0);
    }
    _extent.animateTo(_expanded ? 0 : 1, curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final height = _heightFor(context, _extent.value);
    final desc = (widget.node.description ?? '').trim();
    final expanded = _expanded;

    return Material(
      elevation: 10,
      shadowColor: Colors.black.withValues(alpha: 0.28),
      color: scheme.surface.withValues(alpha: 0.97),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: _onDragUpdate,
          onVerticalDragEnd: _onDragEnd,
          child: Column(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: _onDragUpdate,
                onVerticalDragEnd: _onDragEnd,
                onTap: _toggle,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
                  child: Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: scheme.onSurface.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  controller: _bodyScroll,
                  // Drag is owned by the parent GestureDetector so swipe-down
                  // always moves the drawer; we jump the offset manually on swipe-up.
                  physics: const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + bottom),
                  children: [
                    Text(
                      widget.node.title,
                      style: TextStyle(
                        fontFamily: 'tt_ramilas',
                        fontWeight: FontWeight.w700,
                        fontSize: expanded ? 28 : 22,
                        height: 1.15,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (desc.isNotEmpty)
                      Text(
                        desc,
                        maxLines: expanded ? null : 3,
                        overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurface.withValues(alpha: 0.78),
                              height: 1.4,
                            ),
                      )
                    else
                      Text(
                        'No description yet.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurface.withValues(alpha: 0.45),
                              fontStyle: FontStyle.italic,
                            ),
                      ),
                    if (expanded) ...[
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          if (widget.canViewInGraph)
                            FilledButton.icon(
                              onPressed: widget.onViewInGraph,
                              icon: const Icon(Icons.arrow_forward, size: 18),
                              label: const Text('View in graph'),
                            ),
                          OutlinedButton.icon(
                            onPressed: widget.onEdit,
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            label: const Text('Edit'),
                          ),
                          OutlinedButton.icon(
                            onPressed: widget.onDelete,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: scheme.error,
                              side: BorderSide(color: scheme.error.withValues(alpha: 0.55)),
                            ),
                            icon: const Icon(Icons.delete_outline, size: 18),
                            label: const Text('Delete'),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.focusNode,
    required this.suggestions,
    required this.onChanged,
    required this.onSubmit,
    required this.onPick,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final List<TopicChoice> suggestions;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmit;
  final ValueChanged<TopicChoice> onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return TextFieldTapRegion(
      child: Material(
        elevation: 8,
        color: scheme.surface,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (suggestions.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                    itemCount: suggestions.length,
                    separatorBuilder: (_, __) => Divider(height: 1, color: scheme.outlineVariant),
                    itemBuilder: (context, index) {
                      final choice = suggestions[index];
                      final subtitle = choice.description?.trim();
                      return ListTile(
                        dense: true,
                        leading: Icon(Icons.north_west, size: 16, color: scheme.onSurfaceVariant),
                        title: Text(
                          choice.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontFamily: 'tt_ramilas'),
                        ),
                        subtitle: (subtitle == null || subtitle.isEmpty)
                            ? null
                            : Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.bodySmall?.copyWith(
                                  fontFamily: 'tt_ramilas',
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                        onTap: () => onPick(choice),
                      );
                    },
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: controller,
                        focusNode: focusNode,
                        autofocus: true,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: 'Search a topic',
                          hintStyle: TextStyle(color: scheme.onSurfaceVariant),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                        onChanged: onChanged,
                        onSubmitted: (_) => onSubmit(),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Search',
                      onPressed: onSubmit,
                      color: scheme.onSurfaceVariant,
                      icon: const Icon(Icons.search),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GraphView extends StatefulWidget {
  const _GraphView({
    required this.layout,
    required this.focusId,
    required this.highlightId,
    required this.pendingId,
    required this.transform,
    required this.viewport,
    required this.onSelect,
    required this.onHighlight,
  });

  final GraphLayout layout;
  final String? focusId;
  final String? highlightId;
  final String? pendingId;
  final TransformationController transform;
  final Size viewport;
  final ValueChanged<PlacedNode> onSelect;
  final ValueChanged<PlacedNode?> onHighlight;

  @override
  State<_GraphView> createState() => _GraphViewState();
}

class _GraphViewState extends State<_GraphView> {
  String? _centerId;

  @override
  void initState() {
    super.initState();
    widget.transform.addListener(_onTransform);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onTransform());
  }

  @override
  void didUpdateWidget(covariant _GraphView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transform != widget.transform) {
      oldWidget.transform.removeListener(_onTransform);
      widget.transform.addListener(_onTransform);
    }
    if (oldWidget.layout != widget.layout ||
        oldWidget.viewport != widget.viewport ||
        oldWidget.focusId != widget.focusId) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onTransform());
    }
  }

  @override
  void dispose() {
    widget.transform.removeListener(_onTransform);
    super.dispose();
  }

  void _onTransform() {
    if (!mounted) return;
    final next = _tileAtViewportCenter(
      layout: widget.layout,
      transform: widget.transform.value,
      viewport: widget.viewport,
      currentId: _centerId,
    );
    if (next == _centerId) return;
    setState(() => _centerId = next);
    PlacedNode? node;
    if (next != null) {
      for (final n in widget.layout.nodes) {
        if (n.id == next) {
          node = n;
          break;
        }
      }
    }
    widget.onHighlight(node);
  }

  @override
  Widget build(BuildContext context) {
    const shadowPad = 14.0;
    // Largest (focus flower) under smaller hexes so outer tiles stay tappable.
    final ordered = [...widget.layout.nodes]
      ..sort((a, b) => (b.width * b.height).compareTo(a.width * a.height));
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final node in ordered)
            Positioned(
              left: node.x - shadowPad,
              top: node.y - shadowPad,
              width: node.width + shadowPad * 2,
              height: node.height + shadowPad * 2,
              child: Padding(
                padding: const EdgeInsets.all(shadowPad),
                child: _NodeCard(
                  node: node,
                  focused: node.id == widget.focusId,
                  pending: node.id == widget.pendingId,
                  centerHighlight: node.id == (widget.highlightId ?? _centerId),
                  onTap: () => widget.onSelect(node),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Pick the tile covering the viewport center, with sticky hysteresis to avoid flicker.
String? _tileAtViewportCenter({
  required GraphLayout layout,
  required Matrix4 transform,
  required Size viewport,
  required String? currentId,
}) {
  if (layout.nodes.isEmpty || viewport.isEmpty) return null;
  Matrix4 inverse;
  try {
    inverse = Matrix4.inverted(transform);
  } catch (_) {
    return currentId;
  }
  final center = MatrixUtils.transformPoint(
    inverse,
    Offset(viewport.width / 2, viewport.height / 2),
  );

  for (final node in layout.nodes) {
    if (node.contains(center)) return node.id;
  }

  PlacedNode? best;
  var bestDist = double.infinity;
  for (final node in layout.nodes) {
    final dist = (node.center - center).distance;
    if (dist < bestDist) {
      bestDist = dist;
      best = node;
    }
  }
  if (best == null) return currentId;

  if (currentId != null) {
    for (final node in layout.nodes) {
      if (node.id != currentId) continue;
      final stick = (node.isFlower ? node.radius * 1.1 : node.radius * 0.55);
      final currentDist = (node.center - center).distance;
      if (bestDist > currentDist - stick) return currentId;
      break;
    }
  }
  return best.id;
}

Color _intensifyFill(Color base, double amount, {required bool dark}) {
  if (amount <= 0) return base;
  final hsl = HSLColor.fromColor(base);
  final boosted = dark
      ? hsl
          .withLightness((hsl.lightness + 0.14 * amount).clamp(0.0, 1.0))
          .withSaturation((hsl.saturation + 0.08 * amount).clamp(0.0, 1.0))
      : hsl
          .withLightness((hsl.lightness - 0.10 * amount).clamp(0.0, 1.0))
          .withSaturation((hsl.saturation + 0.18 * amount).clamp(0.0, 1.0));
  return Color.lerp(base, boosted.toColor(), amount)!;
}

class _NodeCard extends StatelessWidget {
  const _NodeCard({
    required this.node,
    required this.focused,
    required this.pending,
    required this.centerHighlight,
    required this.onTap,
  });

  final PlacedNode node;
  final bool focused;
  final bool pending;
  final bool centerHighlight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final base = pending
        ? (dark ? const Color(0xFF3A4554) : const Color(0xFFDDE7F4))
        : nodeFill(node, scheme);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: centerHighlight ? 1.0 : 0.0),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (context, spotlight, _) {
        // Focus flower: shadow only — color/scale look wrong on the big tile.
        final fill = node.isFlower ? base : _intensifyFill(base, spotlight, dark: dark);
        final scale = node.isFlower ? 1.0 : 1.0 + 0.045 * spotlight;
        final child = node.isFlower
            ? _flowerCard(
                scheme: scheme,
                fill: fill,
                dark: dark,
                spotlight: spotlight,
              )
            : _tileCard(
                scheme: scheme,
                fill: fill,
                dark: dark,
                spotlight: spotlight,
              );
        // Clip to hex/flower silhouette so the focus AABB cannot steal taps
        // meant for neighbors-of-neighbors sitting in its bounding box.
        return ClipPath(
          clipper: node.isFlower ? const _FlowerTapClipper() : const _HexTapClipper(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Transform.scale(
              scale: scale,
              child: child,
            ),
          ),
        );
      },
    );
  }

  Widget _flowerCard({
    required ColorScheme scheme,
    required Color fill,
    required bool dark,
    required double spotlight,
  }) {
    return CustomPaint(
      painter: _HexFlowerPainter(color: fill, dark: dark, spotlight: spotlight),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: node.radius * 0.42,
          vertical: node.radius * 0.55,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final scaler = MediaQuery.textScalerOf(context);
            final maxW = constraints.maxWidth;
            final maxH = constraints.maxHeight;
            if (maxW <= 1 || maxH <= 1) return const SizedBox.shrink();

            const titleMaxLines = 3;
            final titleStyleBase = TextStyle(
              fontFamily: 'tt_ramilas',
              height: 1.1,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            );
            final titleLaid = layoutTitle(
              text: node.title,
              style: titleStyleBase,
              maxWidth: maxW,
              maxHeight: maxH * 0.9,
              maxLines: titleMaxLines,
              minFontSize: 12,
              maxFontSize: (node.radius * 0.48).clamp(16.0, 28.0),
              textScaler: scaler,
              hyphenateAtMinSize: true,
            );
            final titleStyle = titleStyleBase.copyWith(fontSize: titleLaid.fontSize);

            return Center(
              child: Text(
                titleLaid.text,
                textAlign: TextAlign.center,
                softWrap: true,
                maxLines: titleMaxLines,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _tileCard({
    required ColorScheme scheme,
    required Color fill,
    required bool dark,
    required double spotlight,
  }) {
    return CustomPaint(
      painter: _HexTilePainter(color: fill, dark: dark, spotlight: spotlight),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: node.radius * 0.34,
          vertical: node.radius * 0.24,
        ),
        child: Center(
          child: _FittingLabel(
            text: node.title,
            maxLines: 4,
            minFontSize: 10,
            maxFontSize: (node.radius * 0.32).clamp(11.0, 17.0),
            hyphenateWords: true,
            style: TextStyle(
              fontFamily: 'tt_ramilas',
              height: 1.15,
              fontWeight: FontWeight.w500,
              color: scheme.onSurface.withValues(alpha: 0.9),
            ),
          ),
        ),
      ),
    );
  }
}

/// Scales font to the tile. Titles keep whole words until min size, then hyphenate.
class _FittingLabel extends StatelessWidget {
  const _FittingLabel({
    required this.text,
    required this.style,
    required this.maxLines,
    required this.minFontSize,
    required this.maxFontSize,
    this.hyphenateWords = false,
    this.align = Alignment.center,
  });

  final String text;
  final TextStyle style;
  final int maxLines;
  final double minFontSize;
  final double maxFontSize;
  final bool hyphenateWords;
  final Alignment align;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = (constraints.maxWidth - 2).clamp(0.0, double.infinity);
        final maxHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : maxWidth * 2;
        if (maxWidth <= 1 || text.trim().isEmpty) {
          return const SizedBox.shrink();
        }
        final laidOut = layoutTitle(
          text: text,
          style: style,
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          maxLines: maxLines,
          minFontSize: minFontSize,
          maxFontSize: maxFontSize,
          textScaler: scaler,
          hyphenateAtMinSize: hyphenateWords,
        );
        return SizedBox.expand(
          child: Align(
            alignment: align,
            child: Text(
              laidOut.text,
              textAlign: TextAlign.center,
              softWrap: true,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: style.copyWith(fontSize: laidOut.fontSize),
            ),
          ),
        );
      },
    );
  }
}

void _paintHexDepth(
  Canvas canvas,
  Path path,
  Color color, {
  required bool dark,
  double spotlight = 0,
}) {
  final lift = spotlight.clamp(0.0, 1.0);
  // Soft halo in every direction (drawShadow only falls downward).
  final halo = Paint()
    ..color = dark
        ? Colors.white.withValues(alpha: 0.12 + 0.14 * lift)
        : Colors.black.withValues(alpha: 0.12 + 0.12 * lift)
    ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4.5 + 4.0 * lift);
  canvas.drawPath(path, halo);
  if (lift > 0.05) {
    final outer = Paint()
      ..color = dark
          ? Colors.white.withValues(alpha: 0.06 * lift)
          : Colors.black.withValues(alpha: 0.06 * lift)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 8 + 4 * lift);
    canvas.drawPath(path, outer);
  }
  canvas.drawPath(path, Paint()..color = color);
  final bounds = path.getBounds();
  final highlight = Paint()
    ..shader = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: dark
          ? [
              Colors.white.withValues(alpha: 0.14),
              Colors.white.withValues(alpha: 0.0),
              Colors.black.withValues(alpha: 0.22),
            ]
          : [
              Colors.white.withValues(alpha: 0.16),
              Colors.white.withValues(alpha: 0.0),
              Colors.black.withValues(alpha: 0.10),
            ],
      stops: const [0.0, 0.45, 1.0],
    ).createShader(bounds);
  canvas.save();
  canvas.clipPath(path);
  canvas.drawRect(bounds, highlight);
  canvas.restore();
}

class _FlowerTapClipper extends CustomClipper<Path> {
  const _FlowerTapClipper();

  @override
  Path getClip(Size size) {
    final unit = hexFlowerBounds(1.0);
    final lattice = math.min(size.width / unit.width, size.height / unit.height);
    return hexFlowerPath(
      latticeSize: lattice,
      center: Offset(size.width / 2, size.height / 2),
    );
  }

  @override
  bool shouldReclip(covariant _FlowerTapClipper oldClipper) => false;
}

class _HexTapClipper extends CustomClipper<Path> {
  const _HexTapClipper();

  @override
  Path getClip(Size size) {
    final lattice = math.min(size.width / 2, size.height / math.sqrt(3));
    return flatHexPath(
      lattice * (1 - hexGapInset),
      center: Offset(size.width / 2, size.height / 2),
    );
  }

  @override
  bool shouldReclip(covariant _HexTapClipper oldClipper) => false;
}

class _HexFlowerPainter extends CustomPainter {
  _HexFlowerPainter({required this.color, required this.dark, this.spotlight = 0});

  final Color color;
  final bool dark;
  final double spotlight;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = hexFlowerBounds(1.0);
    final lattice = math.min(size.width / unit.width, size.height / unit.height);
    final path = hexFlowerPath(
      latticeSize: lattice,
      center: Offset(size.width / 2, size.height / 2),
    );
    _paintHexDepth(canvas, path, color, dark: dark, spotlight: spotlight);
  }

  @override
  bool shouldRepaint(covariant _HexFlowerPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.dark != dark ||
      oldDelegate.spotlight != spotlight;
}

class _HexTilePainter extends CustomPainter {
  _HexTilePainter({required this.color, required this.dark, this.spotlight = 0});

  final Color color;
  final bool dark;
  final double spotlight;

  @override
  void paint(Canvas canvas, Size size) {
    final lattice = math.min(size.width / 2, size.height / math.sqrt(3));
    final path = flatHexPath(
      lattice * (1 - hexGapInset),
      center: Offset(size.width / 2, size.height / 2),
    );
    _paintHexDepth(canvas, path, color, dark: dark, spotlight: spotlight);
  }

  @override
  bool shouldRepaint(covariant _HexTilePainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.dark != dark ||
      oldDelegate.spotlight != spotlight;
}
