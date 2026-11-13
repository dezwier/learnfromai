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

class _GraphScreenState extends State<GraphScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _transform = TransformationController();
  late final AnimationController _panController;
  late final AnimationController _layoutMorph;
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
  var _jobsPanelOpen = false;
  PlacedNode? _highlighted;
  GraphLayout? _layout;
  GraphLayout? _settledLayout;
  GraphLayout? _morphFrom;
  GraphLayout? _morphTo;
  Size _viewport = Size.zero;
  Timer? _dwellTimer;
  /// Cached completeness for highlighted nodes: true = under the user's budget.
  final Map<String, bool> _incompleteByNode = {};
  var _handlingJobCompletion = false;
  var _pendingFocusMorph = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _panController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    )..addListener(_onPanTick);
    _layoutMorph = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    )..addListener(_onLayoutMorphTick);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _resumed) return;
      _resumed = true;
      unawaited(context.read<GraphController>().resume());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    // Phone unlocked / app foregrounded — reattach to server-side jobs.
    unawaited(context.read<GraphController>().reattachJobs());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dwellTimer?.cancel();
    _suggestDebounce?.cancel();
    _panController
      ..removeListener(_onPanTick)
      ..dispose();
    _layoutMorph
      ..removeListener(_onLayoutMorphTick)
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

  void _onLayoutMorphTick() {
    if (!mounted) return;
    setState(() {});
    if (!_layoutMorph.isCompleted) return;
    _morphFrom = null;
    _morphTo = null;
    // Neighbors finished rearranging — ease the grown focus into true center.
    _animateCameraToCanvasCenter(
      viewport: _viewport,
      canvas: Size(_settledLayout?.width ?? _viewport.width, _settledLayout?.height ?? _viewport.height),
    );
  }

  GraphLayout _displayLayout(GraphLayout settled) {
    final from = _morphFrom;
    final to = _morphTo;
    if (from != null && to != null && (_layoutMorph.isAnimating || _layoutMorph.value < 1)) {
      if (_layoutMorph.isCompleted) return settled;
      return morphGraphLayouts(from, to, _layoutMorph.value);
    }
    return settled;
  }

  void _beginFocusMorph({
    required GraphLayout previous,
    required GraphLayout next,
    required String focusId,
    required Size viewport,
  }) {
    PlacedNode? nextFocus;
    for (final node in next.nodes) {
      if (node.id == focusId) {
        nextFocus = node;
        break;
      }
    }
    // Keep the tapped/highlighted tile fixed on screen while it grows into focus.
    Offset screenPin = Offset(viewport.width / 2, viewport.height / 2);
    for (final node in previous.nodes) {
      if (node.id != focusId) continue;
      screenPin = MatrixUtils.transformPoint(_transform.value, node.center);
      break;
    }
    final aligned = nextFocus == null
        ? previous
        : shiftLayoutToAnchor(previous, focusId, nextFocus.center);
    _morphFrom = aligned;
    _morphTo = next;
    _settledLayout = next;
    _panController.stop();
    _panAnimation = null;
    if (nextFocus != null) {
      final scale = _transform.value.getMaxScaleOnAxis();
      _transform.value = _matrixPinning(
        nextFocus.center,
        screenPin,
        scale: scale,
      );
    }
    _layoutMorph.forward(from: 0);
  }

  void _adoptLayout({
    required GraphLayout next,
    required String? focusId,
    required Size viewport,
  }) {
    final previous = _settledLayout;
    final focusChanged = focusId != _transformFocusId;
    if (!focusChanged || previous == null || focusId == null || previous.nodes.isEmpty) {
      _settledLayout = next;
      _morphFrom = null;
      _morphTo = null;
      _layoutMorph.stop();
      _layoutMorph.value = 1;
      if (focusChanged) {
        _snapCameraToCanvasCenter(focusId: focusId, viewport: viewport, canvas: Size(next.width, next.height));
      }
      return;
    }
    _transformFocusId = focusId;
    _panTargetId = null;
    _dwellTimer?.cancel();
    _beginFocusMorph(previous: previous, next: next, focusId: focusId, viewport: viewport);
  }

  void _snapCameraToCanvasCenter({
    required String? focusId,
    required Size viewport,
    required Size canvas,
  }) {
    _transformFocusId = focusId;
    _panController.stop();
    _panAnimation = null;
    _panTargetId = null;
    _dwellTimer?.cancel();
    _transform.value = Matrix4.translationValues(
      (viewport.width - canvas.width) / 2,
      (viewport.height - canvas.height) / 2,
      0,
    );
  }

  void _animateCameraToCanvasCenter({required Size viewport, required Size canvas}) {
    if (viewport.isEmpty) return;
    final end = Matrix4.translationValues(
      (viewport.width - canvas.width) / 2,
      (viewport.height - canvas.height) / 2,
      0,
    );
    final begin = _transform.value.clone();
    _panController.stop();
    _panAnimation = Matrix4Tween(begin: begin, end: end).animate(
      CurvedAnimation(parent: _panController, curve: Curves.easeInOutCubic),
    );
    unawaited(_panController.forward(from: 0).then((_) {
      if (!mounted) return;
      _panAnimation = null;
    }));
  }

  Matrix4 _matrixCentering(Offset scenePoint, Size viewport, {required double scale}) {
    return _matrixPinning(scenePoint, Offset(viewport.width / 2, viewport.height / 2), scale: scale);
  }

  /// Place [scenePoint] at [screenPoint] under the current scale.
  Matrix4 _matrixPinning(Offset scenePoint, Offset screenPoint, {required double scale}) {
    return Matrix4.identity()
      ..translateByDouble(screenPoint.dx, screenPoint.dy, 0, 1)
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

  void _selectNode(PlacedNode node, {bool keepDrawerRaised = false}) {
    _panTargetId = node.id;
    final changed = _highlighted?.id != node.id ||
        _highlighted?.title != node.title ||
        _highlighted?.description != node.description;
    if (changed) {
      _dwellTimer?.cancel();
      setState(() {
        if (_highlighted?.id != node.id && !keepDrawerRaised) {
          _drawerRaised = false;
        }
        _highlighted = node;
      });
    }
    // Dwell only after the pan settles so center-highlight flicker cannot reset it.
    unawaited(() async {
      await _animatePanTo(node.center, _viewport);
      if (!mounted || _highlighted?.id != node.id) return;
      _scheduleDwell(node.id);
    }());
  }

  void _onHighlightFromCenter(PlacedNode? node) {
    if (!mounted) return;
    final pin = _panTargetId;
    // Keep the pan pin until the animation finishes — do not clear on first match.
    if (pin != null && node?.id != pin) return;
    if (node?.id == _highlighted?.id &&
        node?.title == _highlighted?.title &&
        node?.description == _highlighted?.description) {
      return;
    }
    final idChanged = _highlighted?.id != node?.id;
    setState(() {
      if (idChanged) _drawerRaised = false;
      _highlighted = node;
    });
    // Only start dwell from free-pan when not mid animated pan-to-tile.
    if (idChanged && pin == null) _scheduleDwell(node?.id);
  }

  /// null = unknown, true = incomplete, false = complete.
  bool? _knownIncomplete(String id, GraphController graph) {
    if (id == graph.focusId) return graph.categoryGraph?['incomplete'] == true;
    return _incompleteByNode[id];
  }

  void _scheduleDwell(String? nodeId) {
    _dwellTimer?.cancel();
    if (nodeId == null) return;
    final graph = context.read<GraphController>();
    if (nodeId == graph.focusId) {
      _incompleteByNode[nodeId] = graph.categoryGraph?['incomplete'] == true;
      return;
    }
    _dwellTimer = Timer(const Duration(seconds: 1), () {
      unawaited(_onDwell(nodeId));
    });
  }

  Future<void> _onDwell(String nodeId) async {
    if (!mounted || _highlighted?.id != nodeId) return;
    final graph = context.read<GraphController>();
    if (nodeId == graph.focusId) return;
    final payload = await graph.fetchGraph(nodeId);
    if (!mounted || _highlighted?.id != nodeId) return;
    if (payload == null) return;
    final incomplete = payload['incomplete'] == true;
    setState(() => _incompleteByNode[nodeId] = incomplete);
    // Always refocus — show whatever neighbors exist; Request only if under budget.
    await graph.openExisting(nodeId, title: _highlighted?.title, knownPayload: payload);
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _syncHighlightedFromLayout(graph.focusId);
  }

  Future<void> _goToHighlighted(GraphController graph) async {
    final node = _highlighted;
    if (node == null || node.id == graph.focusId) return;
    await graph.openExisting(node.id, title: node.title);
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _syncHighlightedFromLayout(graph.focusId);
  }

  Future<void> _requestNeighbors(GraphController graph) async {
    final node = _highlighted;
    if (node == null) return;
    await graph.enqueueNeighborhood(node.id, title: node.title);
  }

  Future<void> _handleJobCompleted(GraphController graph) async {
    final id = graph.lastCompletedNodeId;
    if (id == null || _handlingJobCompletion) return;
    _handlingJobCompletion = true;
    graph.clearLastCompleted();
    _incompleteByNode[id] = false;
    try {
      if (_highlighted?.id != id) {
        if (mounted) setState(() {});
        return;
      }
      final payload = await graph.fetchGraph(id);
      if (!mounted) return;
      if (payload != null) {
        await graph.openExisting(id, title: _highlighted?.title, knownPayload: payload);
      } else {
        await graph.openExisting(id, title: _highlighted?.title);
      }
      if (!mounted) return;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      _syncHighlightedFromLayout(graph.focusId);
      if (mounted) setState(() {});
    } finally {
      _handlingJobCompletion = false;
    }
  }

  Future<void> _openRelatedTopic(GraphController graph, PlacedNode node) async {
    // Keep the drawer on the destination topic while the graph loads — no blank gap.
    setState(() => _highlighted = node);
    await graph.openExisting(node.id, title: node.title);
    if (!mounted) return;
    // Let LayoutBuilder apply the post-fill graph before syncing the drawer node.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _syncHighlightedFromLayout(graph.focusId);
  }

  Future<void> _openTrackedJob(GraphController graph, TrackedJob job) async {
    PlacedNode? placed;
    final layout = _layout;
    if (layout != null) {
      for (final n in layout.nodes) {
        if (n.id == job.nodeId) {
          placed = n;
          break;
        }
      }
    }
    if (placed != null) {
      _selectNode(placed, keepDrawerRaised: _drawerRaised);
      return;
    }
    await graph.openExisting(job.nodeId, title: job.title);
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _syncHighlightedFromLayout(job.nodeId);
  }

  void _syncHighlightedFromLayout(String? focusId) {
    final layout = _layout;
    final current = _highlighted;
    if (layout == null || current == null) return;
    final targetId = focusId ?? current.id;
    for (final n in layout.nodes) {
      if (n.id != targetId) continue;
      if (n.id == current.id &&
          n.title == current.title &&
          n.description == current.description &&
          n.role == current.role) {
        return;
      }
      setState(() => _highlighted = n);
      return;
    }
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
    final highlight = _highlighted;
    final knownIncomplete =
        highlight == null ? null : _knownIncomplete(highlight.id, graph);
    final canRequestNeighbors = !_searchOpen &&
        !_profileOpen &&
        highlight != null &&
        knownIncomplete == true &&
        graph.jobForNode(highlight.id) == null;
    final canGoToHighlight = !_searchOpen &&
        !_profileOpen &&
        highlight != null &&
        highlight.id != graph.focusId;
    // Show whatever neighbors we already have; Request covers under-budget fills.
    final showRelations = highlight != null;
    // Hide graph chrome while the sheet is up — drawer is stacked above these floats.
    final showFloats = !_searchOpen && !_profileOpen && !_drawerRaised;
    if (_jobsPanelOpen && !graph.hasActiveJobs) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_jobsPanelOpen) return;
        setState(() => _jobsPanelOpen = false);
      });
    }
    if (graph.lastCompletedNodeId != null && !_handlingJobCompletion) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_handleJobCompleted(graph));
      });
    }
    return Scaffold(
      // Keep the graph still when the keyboard opens; search floats above it.
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Column(
            children: [
              if (graph.categoryGraph?['incomplete'] == true && !_drawerRaised)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 8, 20, 4),
                  child: Text('Some surrounding topics are still loading. Open this topic again to continue.'),
                ),
              if (graph.error != null && !_drawerRaised)
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
          if (!_profileOpen && !_drawerRaised) const ProfileTopFade(),
          if (!_profileOpen && !_drawerRaised)
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
          // Floats under the drawer so a raised sheet fully covers them.
          if (showFloats)
            Positioned(
              left: 16,
              bottom: floatBottom,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_jobsPanelOpen && graph.hasActiveJobs) ...[
                    _JobsPanel(
                      jobs: graph.trackedJobs.where((j) => j.isActive).toList(),
                      onSelect: (job) {
                        setState(() => _jobsPanelOpen = false);
                        unawaited(_openTrackedJob(graph, job));
                      },
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (graph.hasActiveJobs)
                    _JobsBadgeButton(
                      count: graph.activeJobCount,
                      open: _jobsPanelOpen,
                      onPressed: () => setState(() => _jobsPanelOpen = !_jobsPanelOpen),
                    ),
                ],
              ),
            ),
          if (showFloats)
            Positioned(
              right: 16,
              bottom: floatBottom,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (canRequestNeighbors) ...[
                    FloatingActionButton.small(
                      heroTag: 'graph-request',
                      tooltip: 'Request neighbors',
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                      elevation: 1.5,
                      focusElevation: 2,
                      hoverElevation: 2,
                      highlightElevation: 2,
                      onPressed: () => unawaited(_requestNeighbors(graph)),
                      child: const Icon(Icons.auto_awesome, size: 20),
                    ),
                    const SizedBox(height: 10),
                  ] else if (canGoToHighlight) ...[
                    FloatingActionButton.small(
                      heroTag: 'graph-go',
                      tooltip: 'Go to topic',
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                      elevation: 1.5,
                      focusElevation: 2,
                      hoverElevation: 2,
                      highlightElevation: 2,
                      onPressed: () => unawaited(_goToHighlighted(graph)),
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
          if (drawerVisible)
            Positioned.fill(
              child: _HighlightDrawer(
                node: _highlighted!,
                layout: _layout,
                focusId: graph.focusId,
                busy: graph.jobForNode(_highlighted!.id) != null,
                progressMessage: graph.jobForNode(_highlighted!.id)?.progressMessage,
                showRelations: showRelations,
                canRequestNeighbors: canRequestNeighbors,
                canViewInGraph: canGoToHighlight,
                onRaisedChanged: (raised) {
                  if (_drawerRaised == raised) return;
                  setState(() => _drawerRaised = raised);
                },
                onRequestNeighbors: () => unawaited(_requestNeighbors(graph)),
                onViewInGraph: () => unawaited(_goToHighlighted(graph)),
                onEdit: () => _editHighlighted(graph),
                onDelete: () => _confirmDeleteHighlighted(graph),
                onOpenRelated: (node) => unawaited(_openRelatedTopic(graph, node)),
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
        final nextLayout = _layoutFor(graph, viewport);
        final focusId = graph.focusId;
        if (_settledLayout == null || focusId != _transformFocusId) {
          if (!_pendingFocusMorph) {
            _pendingFocusMorph = true;
            final previous = _settledLayout;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _pendingFocusMorph = false;
              if (!mounted) return;
              if (previous != null && focusId != null && focusId != _transformFocusId) {
                _adoptLayout(next: nextLayout, focusId: focusId, viewport: viewport);
              } else if (_settledLayout == null || focusId != _transformFocusId) {
                _adoptLayout(next: nextLayout, focusId: focusId, viewport: viewport);
              }
            });
          }
        } else if (!_layoutMorph.isAnimating) {
          _settledLayout = nextLayout;
        }
        final layout = _displayLayout(_settledLayout ?? nextLayout);
        _layout = layout;
        final highlighted = _highlighted;
        if (highlighted != null && !_layoutMorph.isAnimating) {
          final focus = graph.focusId;
          final matchId = focus == highlighted.id ? focus : highlighted.id;
          for (final n in layout.nodes) {
            if (n.id != matchId) continue;
            if (n.role != highlighted.role ||
                n.title != highlighted.title ||
                n.description != highlighted.description) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                _syncHighlightedFromLayout(matchId);
              });
            }
            break;
          }
        }
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
              morphing: _layoutMorph.isAnimating,
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

class _JobsBadgeButton extends StatelessWidget {
  const _JobsBadgeButton({
    required this.count,
    required this.open,
    required this.onPressed,
  });

  final int count;
  final bool open;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Badge(
      isLabelVisible: count > 0,
      label: Text('$count'),
      child: FloatingActionButton.small(
        heroTag: 'graph-jobs',
        tooltip: open ? 'Hide job queue' : 'Show running jobs',
        backgroundColor: open ? scheme.primary : scheme.surfaceContainerHighest,
        foregroundColor: open ? scheme.onPrimary : scheme.onSurfaceVariant,
        elevation: 1.5,
        focusElevation: 2,
        hoverElevation: 2,
        highlightElevation: 2,
        onPressed: onPressed,
        child: const Icon(Icons.hourglass_top, size: 20),
      ),
    );
  }
}

class _JobsPanel extends StatelessWidget {
  const _JobsPanel({required this.jobs, required this.onSelect});

  final List<TrackedJob> jobs;
  final ValueChanged<TrackedJob> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 6,
      color: scheme.surface.withValues(alpha: 0.97),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280, maxHeight: 280),
        child: ListView.separated(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 6),
          itemCount: jobs.length,
          separatorBuilder: (_, __) => Divider(
            height: 1,
            color: scheme.onSurface.withValues(alpha: 0.06),
          ),
          itemBuilder: (context, index) {
            final job = jobs[index];
            return InkWell(
              onTap: () => onSelect(job),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      job.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      job.progressMessage ?? job.state,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurface.withValues(alpha: 0.65),
                          ),
                    ),
                  ],
                ),
              ),
            );
          },
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
    required this.canRequestNeighbors,
    required this.showRelations,
    required this.onRaisedChanged,
    required this.onRequestNeighbors,
    required this.onViewInGraph,
    required this.onEdit,
    required this.onDelete,
    required this.onOpenRelated,
    this.layout,
    this.focusId,
    this.busy = false,
    this.progressMessage,
  });

  /// Collapsed content height (above the home-indicator inset).
  static const double contentHeight = 130;

  static double collapsedHeight(double safeBottom) => contentHeight + safeBottom;

  final PlacedNode node;
  final GraphLayout? layout;
  final String? focusId;
  final bool busy;
  final String? progressMessage;
  final bool showRelations;
  final bool canRequestNeighbors;
  final bool canViewInGraph;
  final ValueChanged<bool> onRaisedChanged;
  final VoidCallback onRequestNeighbors;
  final VoidCallback onViewInGraph;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<PlacedNode> onOpenRelated;

  @override
  State<_HighlightDrawer> createState() => _HighlightDrawerState();
}

class _HighlightDrawerState extends State<_HighlightDrawer>
    with TickerProviderStateMixin {
  /// 0 = collapsed, 1 = fully expanded (90% of screen).
  late final AnimationController _extent;
  late final AnimationController _bodyFling;
  final _bodyScroll = ScrollController();
  var _reportedRaised = false;
  var _dragMovedDrawer = false;

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
    _bodyFling = AnimationController.unbounded(vsync: this)
      ..addListener(_onBodyFlingTick);
  }

  @override
  void didUpdateWidget(covariant _HighlightDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.id == widget.node.id) return;
    _stopBodyBallistic();
    if (_bodyScroll.hasClients) {
      _bodyScroll.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _extent.removeListener(_onExtentTick);
    _extent.dispose();
    _bodyFling.removeListener(_onBodyFlingTick);
    _bodyFling.dispose();
    _bodyScroll.dispose();
    super.dispose();
  }

  void _onBodyFlingTick() {
    if (!_bodyScroll.hasClients) return;
    final position = _bodyScroll.position;
    final next = _bodyFling.value.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (next != position.pixels) {
      position.jumpTo(next);
    }
    final velocity = _bodyFling.velocity;
    if ((velocity > 0 && next >= position.maxScrollExtent) ||
        (velocity < 0 && next <= position.minScrollExtent)) {
      _bodyFling.stop();
    }
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

  void _scrollBodyBy(double dy) {
    if (!_bodyScroll.hasClients) return;
    final position = _bodyScroll.position;
    position.jumpTo((position.pixels - dy).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    ));
  }

  void _stopBodyBallistic() {
    if (_bodyFling.isAnimating) _bodyFling.stop();
  }

  void _flingBody(double primaryVelocity) {
    if (!_bodyScroll.hasClients) return;
    // Match Scrollable: negate drag velocity so finger-up continues downward.
    // Boost + lower friction so a normal flick coasts farther.
    final velocity = -primaryVelocity * 2.2;
    if (velocity.abs() < 80) return;
    final position = _bodyScroll.position;
    _bodyFling.animateWith(
      ClampingScrollSimulation(
        position: position.pixels,
        velocity: velocity,
        friction: 0.008,
      ),
    );
  }

  void _onDragStart(DragStartDetails details) {
    _dragMovedDrawer = false;
    _stopBodyBallistic();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final dy = details.delta.dy;
    if (dy > 0) {
      // Finger down: scroll list toward top first; only collapse drawer at offset 0.
      if (_fullyOpen && _bodyScroll.hasClients && _bodyScroll.offset > 0) {
        _scrollBodyBy(dy);
        return;
      }
      _dragMovedDrawer = true;
      _applyDragDy(dy);
      return;
    }
    // Finger up: scroll content when fully open, otherwise expand the drawer.
    if (_fullyOpen && _bodyScroll.hasClients) {
      final max = _bodyScroll.position.maxScrollExtent;
      if (_bodyScroll.offset < max) {
        _scrollBodyBy(dy);
        return;
      }
    }
    _dragMovedDrawer = true;
    _applyDragDy(dy);
  }

  void _snap({double velocity = 0}) {
    final opening = velocity < -400 || (velocity <= 400 && _extent.value >= 0.35);
    _extent.animateTo(opening ? 1 : 0, curve: Curves.easeOutCubic);
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    // List-only drags keep the sheet open and continue with inertial scroll.
    if (!_dragMovedDrawer) {
      _dragMovedDrawer = false;
      _flingBody(velocity);
      return;
    }
    _dragMovedDrawer = false;
    _snap(velocity: velocity);
  }

  void _toggle() {
    if (_bodyScroll.hasClients && _bodyScroll.offset > 0) {
      _bodyScroll.jumpTo(0);
    }
    final opening = !_expanded;
    _extent.animateTo(opening ? 1 : 0, curve: Curves.easeOutCubic);
  }

  Future<void> _collapseThen(VoidCallback action) async {
    if (_bodyScroll.hasClients && _bodyScroll.offset > 0) {
      _bodyScroll.jumpTo(0);
    }
    if (_extent.value > 0) {
      await _extent.animateTo(0, curve: Curves.easeOutCubic);
    }
    if (!mounted) return;
    action();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final height = _heightFor(context, _extent.value);
    final desc = (widget.node.description ?? '').trim();
    final expanded = _expanded;
    final scrim = (_extent.value * 0.48).clamp(0.0, 0.48);

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            ignoring: scrim < 0.02,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _extent.animateTo(0, curve: Curves.easeOutCubic),
              child: ColoredBox(color: Colors.black.withValues(alpha: scrim)),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Material(
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
                onVerticalDragStart: _onDragStart,
                onVerticalDragUpdate: _onDragUpdate,
                onVerticalDragEnd: _onDragEnd,
                child: Column(
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragStart: _onDragStart,
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
                            const SizedBox(height: 18),
                            Row(
                              children: [
                                if (widget.canRequestNeighbors) ...[
                                  _DrawerIconButton(
                                    tooltip: 'Request neighbors',
                                    icon: Icons.auto_awesome,
                                    filled: true,
                                    onPressed: widget.onRequestNeighbors,
                                  ),
                                  const SizedBox(width: 8),
                                ] else if (widget.canViewInGraph) ...[
                                  _DrawerIconButton(
                                    tooltip: 'View in graph',
                                    icon: Icons.arrow_forward,
                                    filled: true,
                                    onPressed: () => _collapseThen(widget.onViewInGraph),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                                _DrawerIconButton(
                                  tooltip: 'Edit',
                                  icon: Icons.edit_outlined,
                                  onPressed: widget.onEdit,
                                ),
                                const SizedBox(width: 8),
                                _DrawerIconButton(
                                  tooltip: 'Delete',
                                  icon: Icons.delete_outline,
                                  foreground: scheme.error,
                                  onPressed: widget.onDelete,
                                ),
                              ],
                            ),
                            const SizedBox(height: 18),
                            if (widget.busy) ...[
                              _DrawerProgressCard(
                                message: widget.progressMessage ?? 'Loading related topics…',
                              ),
                              if (widget.showRelations) const SizedBox(height: 12),
                            ],
                            if (widget.showRelations && widget.layout != null)
                              _RelationsCard(
                                node: widget.node,
                                layout: widget.layout!,
                                focusId: widget.focusId,
                                onOpen: widget.onOpenRelated,
                              ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DrawerProgressCard extends StatelessWidget {
  const _DrawerProgressCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.onSurface.withValues(
        alpha: scheme.brightness == Brightness.dark ? 0.10 : 0.045,
      ),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                color: scheme.primary.withValues(alpha: 0.85),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Building neighborhood',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.72),
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    message,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.78),
                          height: 1.35,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RelationsCard extends StatelessWidget {
  const _RelationsCard({
    required this.node,
    required this.layout,
    required this.onOpen,
    this.focusId,
  });

  final PlacedNode node;
  final GraphLayout layout;
  final String? focusId;
  final ValueChanged<PlacedNode> onOpen;

  static const _order = [
    NodeRole.parent,
    NodeRole.sibling,
    NodeRole.child,
    NodeRole.related,
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final groups = relationsFor(node, layout, focusId: focusId);
    final sections = [
      for (final role in _order)
        if ((groups[role] ?? const []).isNotEmpty) (role, groups[role]!),
    ];
    if (sections.isEmpty) {
      return Material(
        color: scheme.onSurface.withValues(
          alpha: scheme.brightness == Brightness.dark ? 0.08 : 0.04,
        ),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Text(
            'No linked topics in this view.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurface.withValues(alpha: 0.45),
                  fontStyle: FontStyle.italic,
                ),
          ),
        ),
      );
    }

    return Material(
      color: scheme.onSurface.withValues(
        alpha: scheme.brightness == Brightness.dark ? 0.10 : 0.045,
      ),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < sections.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                color: scheme.onSurface.withValues(alpha: 0.06),
              ),
            _RelationSection(
              role: sections[i].$1,
              nodes: sections[i].$2,
              onOpen: onOpen,
            ),
          ],
        ],
      ),
    );
  }
}

class _RelationSection extends StatelessWidget {
  const _RelationSection({
    required this.role,
    required this.nodes,
    required this.onOpen,
  });

  final NodeRole role;
  final List<PlacedNode> nodes;
  final ValueChanged<PlacedNode> onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = roleFill(role, scheme);
    final onAccent = scheme.brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.92)
        : const Color(0xFF1A1C1E).withValues(alpha: 0.88);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                relationSectionLabel(role),
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.72),
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
              ),
            ],
          ),
        ),
        for (final item in nodes)
          InkWell(
            onTap: () => onOpen(item),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: item.role == NodeRole.focus
                          ? accent
                          : nodeFill(item, scheme),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _topicInitial(item.title),
                      style: TextStyle(
                        color: onAccent,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: scheme.onSurface.withValues(alpha: 0.9),
                            height: 1.25,
                            fontWeight: FontWeight.w500,
                          ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: scheme.onSurface.withValues(alpha: 0.28),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 4),
      ],
    );
  }
}

String _topicInitial(String title) {
  final trimmed = title.trim();
  if (trimmed.isEmpty) return '?';
  return String.fromCharCode(trimmed.runes.first).toUpperCase();
}

class _DrawerIconButton extends StatelessWidget {
  const _DrawerIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.filled = false,
    this.foreground,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool filled;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = foreground ?? (filled ? scheme.onPrimary : scheme.onSurfaceVariant);
    final bg = filled
        ? scheme.primary
        : scheme.onSurface.withValues(alpha: scheme.brightness == Brightness.dark ? 0.10 : 0.06);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: bg,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, size: 20, color: fg),
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
    this.morphing = false,
  });

  final GraphLayout layout;
  final String? focusId;
  final String? highlightId;
  final String? pendingId;
  final bool morphing;
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
    if (!mounted || widget.morphing) return;
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
                child: Opacity(
                  opacity: node.opacity.clamp(0.0, 1.0),
                  child: IgnorePointer(
                    ignoring: node.opacity < 0.35,
                    child: _NodeCard(
                      node: node,
                      focused: node.id == widget.focusId,
                      pending: node.id == widget.pendingId,
                      centerHighlight:
                          !widget.morphing && node.id == (widget.highlightId ?? _centerId),
                      onTap: () => widget.onSelect(node),
                    ),
                  ),
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
    final flower = node.effectiveFlowerAmount;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: centerHighlight ? 1.0 : 0.0),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (context, spotlight, _) {
        // Focus flower: shadow only — color/scale look wrong on the big tile.
        final fill = flower >= 0.85
            ? base
            : _intensifyFill(base, spotlight * (1 - flower), dark: dark);
        final scale = flower >= 0.85 ? 1.0 : 1.0 + 0.045 * spotlight * (1 - flower);
        final hex = _tileCard(
          scheme: scheme,
          fill: fill,
          dark: dark,
          spotlight: spotlight,
        );
        final bloom = _flowerCard(
          scheme: scheme,
          fill: base,
          dark: dark,
          spotlight: spotlight,
        );
        final child = flower <= 0.02
            ? hex
            : flower >= 0.98
                ? bloom
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      Opacity(opacity: 1 - flower, child: hex),
                      Opacity(opacity: flower, child: bloom),
                    ],
                  );
        // Clip to hex/flower silhouette so the focus AABB cannot steal taps
        // meant for neighbors-of-neighbors sitting in its bounding box.
        return ClipPath(
          clipper: flower >= 0.5 ? const _FlowerTapClipper() : const _HexTapClipper(),
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
