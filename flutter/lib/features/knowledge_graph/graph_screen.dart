import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/media/image_pick.dart';
import '../../core/widgets/pulse_placeholder.dart';
import '../../core/widgets/study_card.dart';
import '../profile/overlay_panel_chrome.dart';
import '../profile/profile_hud.dart';
import '../profile/profile_screen.dart';
import 'graph_controller.dart';
import 'graph_layout.dart';
import 'learn_sheet.dart';
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
  /// While set, ignore center-highlight updates that aren't this id (avoids flicker mid-pan).
  String? _panTargetId;
  Timer? _suggestDebounce;
  Offset? _searchOutsideDown;
  var _searchOutsideMoved = false;
  var _resumed = false;
  var _searchOpen = false;
  var _profileOpen = false;
  var _topicOpen = false;
  var _jobsPanelOpen = false;
  var _imageUploading = false;
  PlacedNode? _highlighted;
  GraphLayout? _layout;
  GraphLayout? _settledLayout;
  GraphLayout? _morphFrom;
  GraphLayout? _morphTo;
  Size _viewport = Size.zero;
  Timer? _dwellTimer;
  Timer? _motionSettleTimer;
  /// True while a finger is actively dragging/pinching the graph.
  var _graphGestureActive = false;
  /// Cached completeness for highlighted nodes: true = under the user's budget.
  final Map<String, bool> _incompleteByNode = {};
  var _handlingJobCompletion = false;
  var _pendingFocusMorph = false;
  /// Relation tap in flight — keep topic screen stable until the new focus lands.
  String? _openingRelatedId;

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
      duration: const Duration(milliseconds: 360),
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
    _motionSettleTimer?.cancel();
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

  static bool _transformNearlyStill(Matrix4 a, Matrix4 b) {
    final ta = a.getTranslation();
    final tb = b.getTranslation();
    return (ta - tb).length < 0.4 &&
        (a.getMaxScaleOnAxis() - b.getMaxScaleOnAxis()).abs() < 0.0005;
  }

  void _cancelDwellAndSettle() {
    _dwellTimer?.cancel();
    _motionSettleTimer?.cancel();
  }

  /// After the finger lifts, wait until inertia dies, then open the highlight.
  void _armSettleThenDwell() {
    _motionSettleTimer?.cancel();
    _dwellTimer?.cancel();
    if (_graphGestureActive || _panController.isAnimating) return;
    var previous = _transform.value.clone();
    _motionSettleTimer = Timer.periodic(const Duration(milliseconds: 40), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_graphGestureActive || _panController.isAnimating) {
        timer.cancel();
        return;
      }
      final now = _transform.value;
      if (_transformNearlyStill(previous, now)) {
        timer.cancel();
        _scheduleDwell(_highlighted?.id);
      } else {
        previous = now.clone();
        _dwellTimer?.cancel();
      }
    });
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
    _panController.stop();
    _panAnimation = null;
    // Pin camera + seed morph at t=0 in one setState so the first painted
    // frame already matches the screen pin (avoids a one-frame jump).
    if (nextFocus != null) {
      final scale = _transform.value.getMaxScaleOnAxis();
      _transform.value = _matrixPinning(
        nextFocus.center,
        screenPin,
        scale: scale,
      );
    }
    _layoutMorph.stop();
    _layoutMorph.value = 0;
    setState(() {
      _morphFrom = aligned;
      _morphTo = next;
      _settledLayout = next;
    });
    _layoutMorph.forward();
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
    _cancelDwellAndSettle();
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
    _cancelDwellAndSettle();
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

  void _selectNode(PlacedNode node) {
    final graph = context.read<GraphController>();
    // Focus tile: open the topic overlay (no bottom drawer).
    if (node.id == graph.focusId) {
      _dwellTimer?.cancel();
      setState(() {
        _highlighted = node;
        _topicOpen = true;
        _profileOpen = false;
      });
      return;
    }
    _panTargetId = node.id;
    final changed = _highlighted?.id != node.id ||
        _highlighted?.title != node.title ||
        _highlighted?.description != node.description;
    if (changed) {
      _dwellTimer?.cancel();
      setState(() => _highlighted = node);
    }
    // Dwell only after the animated pan finishes and the viewport is still.
    unawaited(() async {
      await _animatePanTo(node.center, _viewport);
      if (!mounted || _highlighted?.id != node.id) return;
      _armSettleThenDwell();
    }());
  }

  void _onHighlightFromCenter(PlacedNode? node) {
    if (!mounted) return;
    // Topic overlay / relation-open owns the selection — don't thrash it
    // from camera morph / recenter.
    if (_openingRelatedId != null || _topicOpen) return;
    final pin = _panTargetId;
    // Keep the pan pin until the animation finishes — do not clear on first match.
    if (pin != null && node?.id != pin) return;
    if (node?.id == _highlighted?.id &&
        node?.title == _highlighted?.title &&
        node?.description == _highlighted?.description) {
      return;
    }
    final idChanged = _highlighted?.id != node?.id;
    setState(() => _highlighted = node);
    // Free-pan dwell is armed from InteractiveViewer settle (finger up + no velocity).
    if (idChanged) _dwellTimer?.cancel();
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
    // No intentional pause — fetch/open as soon as the camera has settled.
    unawaited(_onDwell(nodeId));
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
    final jobType = graph.lastCompletedJobType;
    if (id == null || _handlingJobCompletion) return;
    _handlingJobCompletion = true;
    graph.clearLastCompleted();
    // Learn sheet listens for content jobs itself — don't remount the graph.
    // Image jobs patch image_url on the graph; mirror onto the open topic tile.
    if (jobType == 'expand_content' || jobType == 'generate_image') {
      if (jobType == 'generate_image' && mounted) {
        final urls = _imageUrlsFromGraph(graph, id);
        final current = _highlighted;
        if (current != null &&
            current.id == id &&
            (urls.$1 != current.imageUrl || urls.$2 != current.imageThumbUrl)) {
          setState(
            () => _highlighted = current.copyWith(
              imageUrl: urls.$1,
              imageThumbUrl: urls.$2,
            ),
          );
        } else if (mounted) {
          setState(() {});
        }
      } else if (mounted) {
        setState(() {});
      }
      _handlingJobCompletion = false;
      return;
    }
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
    // Title switches immediately; relations stay pulsed until the new focus settles
    // so we don't flash the old neighborhood's edge view mid-load / morph.
    _panTargetId = node.id;
    setState(() {
      _highlighted = node;
      _openingRelatedId = node.id;
    });
    try {
      await graph.openExisting(node.id, title: node.title);
      if (!mounted) return;
      // Wait for LayoutBuilder's post-frame adopt — not merely the network return.
      for (var i = 0; i < 12; i++) {
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
        if (graph.focusId == node.id && _transformFocusId == node.id) break;
      }
      _syncHighlightedFromLayout(graph.focusId);
    } finally {
      if (mounted && _openingRelatedId == node.id) {
        setState(() => _openingRelatedId = null);
      }
    }
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
      _selectNode(placed);
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
          n.imageUrl == current.imageUrl &&
          n.imageThumbUrl == current.imageThumbUrl &&
          n.role == current.role) {
        return;
      }
      setState(() => _highlighted = n);
      return;
    }
  }

  Future<void> _openLearn(PlacedNode node) async {
    await showLearnSheet(context, nodeId: node.id, title: node.title);
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
        imageUrl: node.imageUrl,
        imageThumbUrl: node.imageThumbUrl,
        viaRole: node.viaRole,
      );
    });
  }

  Future<void> _chooseImageAction(GraphController graph) async {
    final node = _highlighted;
    if (node == null) return;
    final hasImage = (node.imageUrl ?? '').trim().isNotEmpty;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.auto_awesome_outlined),
                title: Text(hasImage ? 'Regenerate with AI' : 'Generate with AI'),
                onTap: () => Navigator.pop(context, 'generate'),
              ),
              ListTile(
                leading: const Icon(Icons.upload_outlined),
                title: Text(hasImage ? 'Replace with upload' : 'Upload image'),
                onTap: () => Navigator.pop(context, 'upload'),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || choice == null) return;
    if (choice == 'generate') {
      await graph.enqueueImage(node.id, title: node.title, regenerate: hasImage);
      return;
    }
    if (choice == 'upload') {
      await _uploadTopicImage(graph, node);
    }
  }

  Future<void> _uploadTopicImage(GraphController graph, PlacedNode node) async {
    final picked = await pickImageBytes();
    if (picked == null || !mounted) return;
    setState(() => _imageUploading = true);
    try {
      final ok = await graph.uploadImage(
        node.id,
        bytes: picked.bytes,
        filename: picked.filename,
        contentType: picked.mimeType,
      );
      if (!ok || !mounted) return;
      _syncHighlightedFromLayout(node.id);
    } finally {
      if (mounted) setState(() => _imageUploading = false);
    }
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
      _topicOpen = false;
    });
  }

  void _closeTopic() {
    if (!_topicOpen) return;
    setState(() => _topicOpen = false);
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
    setState(() {
      _topicOpen = false;
      _profileOpen = true;
    });
  }

  void _closeProfile() {
    if (!_profileOpen) return;
    setState(() => _profileOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    final graph = context.watch<GraphController>();
    graph.preloadGraphImages();
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final scheme = Theme.of(context).colorScheme;
    final highlight = _highlighted;
    final knownIncomplete =
        highlight == null ? null : _knownIncomplete(highlight.id, graph);
    final overlayOpen = _profileOpen || _topicOpen;
    final canRequestNeighbors = !_searchOpen &&
        !overlayOpen &&
        highlight != null &&
        knownIncomplete == true &&
        graph.jobForNode(highlight.id) == null;
    final openingRelated =
        _openingRelatedId != null && _openingRelatedId == highlight?.id;
    final canGoToHighlight = !_searchOpen &&
        !overlayOpen &&
        highlight != null &&
        highlight.id != graph.focusId &&
        !openingRelated;
    // Hide stale/partial relation lists while a topic hop is in flight.
    final showRelations = highlight != null && !openingRelated;
    final showChrome = !_searchOpen && !overlayOpen;
    final chromeOpaque = showChrome;
    final trail = graph.focusTrail;
    // Trail under FABs; search sits just above the row.
    // On iPhone, nestle into the home-indicator inset so the row sits lower.
    const trailHeight = 40.0;
    const trailGap = 6.0;
    final showTrail = showChrome && trail.isNotEmpty;
    final trailBottom = keyboard +
        (safeBottom > 0 ? (safeBottom - 10).clamp(2.0, safeBottom) : 8.0);
    final floatBottom = trailBottom + (showTrail ? trailHeight + trailGap : 8);
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
              if (graph.error != null && !_topicOpen)
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
          if (showChrome)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: ProfileTopFade.height(context),
              child: IgnorePointer(
                ignoring: !chromeOpaque,
                child: AnimatedOpacity(
                  opacity: chromeOpaque ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  child: const ProfileTopFade(),
                ),
              ),
            ),
          if (showChrome)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                ignoring: !chromeOpaque,
                child: AnimatedOpacity(
                  opacity: chromeOpaque ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
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
              ),
            ),
          if (showChrome && chromeOpaque && _jobsPanelOpen)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _jobsPanelOpen = false),
                child: const ColoredBox(color: Color(0x00000000)),
              ),
            ),
          if (showChrome)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: floatBottom + 56,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: chromeOpaque ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          scheme.surface.withValues(alpha: 0.94),
                          scheme.surface.withValues(alpha: 0.72),
                          scheme.surface.withValues(alpha: 0.28),
                          scheme.surface.withValues(alpha: 0.0),
                        ],
                        stops: const [0.0, 0.35, 0.72, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (showChrome)
            Positioned(
              left: 16,
              bottom: floatBottom,
              child: IgnorePointer(
                ignoring: !chromeOpaque,
                child: AnimatedOpacity(
                  opacity: chromeOpaque ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
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
                        const SizedBox(height: 6),
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
              ),
            ),
          if (showChrome)
            Positioned(
              right: 16,
              bottom: floatBottom,
              child: IgnorePointer(
                ignoring: !chromeOpaque,
                child: AnimatedOpacity(
                  opacity: chromeOpaque ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
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
                        const SizedBox(height: 6),
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
                        const SizedBox(height: 6),
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
              ),
            ),
          if (showTrail)
            Positioned(
              left: 0,
              right: 0,
              bottom: trailBottom,
              height: trailHeight,
              child: IgnorePointer(
                ignoring: !chromeOpaque,
                child: AnimatedOpacity(
                  opacity: chromeOpaque ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  child: _FocusTrailBar(
                    entries: trail,
                    currentId: graph.focusId,
                    onSelect: (entry) {
                      if (entry.id == graph.focusId) return;
                      unawaited(graph.openTrailEntry(entry.id));
                    },
                  ),
                ),
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
          if (_topicOpen && _highlighted != null)
            Positioned.fill(
              child: _TopicDetailScreen(
                node: _highlighted!,
                // Settled layout only — morphing display layout thrash-rebuilds relations.
                layout: _settledLayout,
                focusId: graph.focusId,
                busy: graph.jobForNode(_highlighted!.id) != null || _imageUploading,
                progressMessage: _imageUploading
                    ? 'Uploading topic image…'
                    : graph.jobForNode(_highlighted!.id)?.progressMessage,
                imageGenerating: _imageUploading ||
                    graph.jobForNode(_highlighted!.id)?.type == 'generate_image',
                relationsPending: openingRelated,
                showRelations: showRelations,
                canRequestNeighbors:
                    knownIncomplete == true &&
                    graph.jobForNode(_highlighted!.id) == null &&
                    !openingRelated &&
                    !_imageUploading,
                canViewInGraph:
                    _highlighted!.id != graph.focusId && !openingRelated,
                canEditImage:
                    graph.jobForNode(_highlighted!.id) == null && !_imageUploading,
                onClose: _closeTopic,
                onRequestNeighbors: () => unawaited(_requestNeighbors(graph)),
                onViewInGraph: () {
                  _closeTopic();
                  unawaited(_goToHighlighted(graph));
                },
                onLearn: () {
                  final node = _highlighted;
                  if (node == null) return;
                  unawaited(_openLearn(node));
                },
                onImageAction: () => unawaited(_chooseImageAction(graph)),
                onEdit: () => _editHighlighted(graph),
                onDelete: () => _confirmDeleteHighlighted(graph),
                onOpenRelated: (node) => unawaited(_openRelatedTopic(graph, node)),
                loadImageBytes: (url) => graph.fetchImageBytes(url, notify: false),
                cachedImageBytes: graph.cachedImageBytes,
              ),
            ),
        ],
      ),
    );
  }

  bool _hasNodes(GraphController graph) {
    final nodes = graph.categoryGraph?['nodes'];
    return nodes is List && nodes.isNotEmpty;
  }

  (String?, String?) _imageUrlsFromGraph(GraphController graph, String nodeId) {
    final nodes = graph.categoryGraph?['nodes'];
    if (nodes is! List) return (null, null);
    for (final raw in nodes) {
      if (raw is Map && raw['id']?.toString() == nodeId) {
        final url = raw['image_url']?.toString().trim();
        final thumb = raw['image_thumb_url']?.toString().trim();
        return (
          (url == null || url.isEmpty) ? null : url,
          (thumb == null || thumb.isEmpty) ? null : thumb,
        );
      }
    }
    return (null, null);
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
        // First layout: snap the camera in this build so we never paint one frame of
        // identity transform on a wide canvas (looks like a blank drawer from the right).
        if (_settledLayout == null && !viewport.isEmpty) {
          _settledLayout = nextLayout;
          _morphFrom = null;
          _morphTo = null;
          // Avoid notifying _onLayoutMorphTick (setState) during LayoutBuilder.
          _layoutMorph.stop();
          _layoutMorph.removeListener(_onLayoutMorphTick);
          _layoutMorph.value = 1;
          _layoutMorph.addListener(_onLayoutMorphTick);
          _snapCameraToCanvasCenter(
            focusId: focusId,
            viewport: viewport,
            canvas: Size(nextLayout.width, nextLayout.height),
          );
        } else if (_settledLayout == null || focusId != _transformFocusId) {
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
              // Reveal InteractiveViewer after the camera snap (see cameraReady).
              if (mounted) setState(() {});
            });
          }
        } else if (!_layoutMorph.isAnimating) {
          _settledLayout = nextLayout;
        }
        // Never mount InteractiveViewer until the camera matches this focus —
        // constrained:false defaults to top-left and a wide canvas looks like a
        // right-hand drawer for one frame.
        final cameraReady =
            !viewport.isEmpty && _settledLayout != null && _transformFocusId == focusId;
        if (!cameraReady) {
          return ColoredBox(color: Theme.of(context).scaffoldBackgroundColor);
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
                n.description != highlighted.description ||
                n.imageUrl != highlighted.imageUrl ||
                n.imageThumbUrl != highlighted.imageThumbUrl) {
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
            _graphGestureActive = true;
            _cancelDwellAndSettle();
            if (!_panController.isAnimating) return;
            _panController.stop();
            _panAnimation = null;
            _panTargetId = null;
          },
          onInteractionUpdate: (_) {
            _dwellTimer?.cancel();
          },
          onInteractionEnd: (_) {
            _graphGestureActive = false;
            _armSettleThenDwell();
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
              imageBytesFor: graph.cachedImageBytes,
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
            imageUrl: raw['image_url']?.toString(),
            imageThumbUrl: raw['image_thumb_url']?.toString(),
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

class _FocusTrailBar extends StatefulWidget {
  const _FocusTrailBar({
    required this.entries,
    required this.currentId,
    required this.onSelect,
  });

  final List<FocusTrailEntry> entries;
  final String? currentId;
  final ValueChanged<FocusTrailEntry> onSelect;

  @override
  State<_FocusTrailBar> createState() => _FocusTrailBarState();
}

class _FocusTrailBarState extends State<_FocusTrailBar> {
  /// Ids that have finished their entrance (or were present at cold start).
  final Set<String> _settled = {};

  /// Match focus morph so the chip eases in alongside the graph.
  static const _enter = Duration(milliseconds: 360);

  @override
  void initState() {
    super.initState();
    _settled.addAll(widget.entries.map((e) => e.id));
  }

  @override
  void didUpdateWidget(covariant _FocusTrailBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextIds = widget.entries.map((e) => e.id).toSet();
    _settled.removeWhere((id) => !nextIds.contains(id));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // reverse keeps newest pinned on the right. Entrance widthFactor grows the
    // new chip from the right so the row shifts left in the same motion.
    // Do not mark ids settled until onEnd — morph setStates would otherwise
    // flip animate→false mid-tween and snap.
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth - 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < widget.entries.length; i++) ...[
                    if (i > 0) const SizedBox(width: 6),
                    () {
                      final entry = widget.entries[i];
                      return _FocusTrailChipReveal(
                        key: ValueKey(entry.id),
                        animate: !_settled.contains(entry.id),
                        duration: _enter,
                        onFinished: () {
                          if (!mounted) return;
                          setState(() => _settled.add(entry.id));
                        },
                        child: _FocusTrailChip(
                          entry: entry,
                          current: entry.id == widget.currentId,
                          onTap: () => widget.onSelect(entry),
                          scheme: scheme,
                        ),
                      );
                    }(),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _FocusTrailChipReveal extends StatelessWidget {
  const _FocusTrailChipReveal({
    super.key,
    required this.animate,
    required this.duration,
    required this.onFinished,
    required this.child,
  });

  final bool animate;
  final Duration duration;
  final VoidCallback onFinished;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!animate) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration,
      curve: Curves.easeOutCubic,
      onEnd: onFinished,
      builder: (context, t, child) {
        return ClipRect(
          child: Align(
            alignment: Alignment.centerRight,
            widthFactor: t.clamp(0.001, 1.0),
            child: Opacity(opacity: t, child: child),
          ),
        );
      },
      child: child,
    );
  }
}

class _FocusTrailChip extends StatelessWidget {
  const _FocusTrailChip({
    required this.entry,
    required this.current,
    required this.onTap,
    required this.scheme,
  });

  final FocusTrailEntry entry;
  final bool current;
  final VoidCallback onTap;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final bg = current
        ? scheme.primary.withValues(alpha: 0.16)
        : scheme.surfaceContainerHighest.withValues(alpha: 0.92);
    final border = current
        ? scheme.primary.withValues(alpha: 0.55)
        : scheme.onSurface.withValues(alpha: 0.08);
    final fg = current ? scheme.primary : scheme.onSurface.withValues(alpha: 0.78);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: ShapeDecoration(
            color: bg,
            shape: StadiumBorder(side: BorderSide(color: border)),
            shadows: current
                ? null
                : const [
                    BoxShadow(color: Color(0x42000000), blurRadius: 2, offset: Offset(0, 0.5)),
                  ],
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 148),
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              style: TextStyle(
                fontFamily: 'tt_ramilas',
                fontSize: 13,
                fontWeight: current ? FontWeight.w700 : FontWeight.w600,
                height: 1.1,
                color: fg,
              ),
              child: Text(
                entry.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ),
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

/// Fullscreen topic overlay — same chrome pattern as [ProfileScreen].
class _TopicDetailScreen extends StatelessWidget {
  const _TopicDetailScreen({
    required this.node,
    required this.canViewInGraph,
    required this.canRequestNeighbors,
    required this.showRelations,
    required this.onClose,
    required this.onRequestNeighbors,
    required this.onViewInGraph,
    required this.onLearn,
    required this.onImageAction,
    required this.onEdit,
    required this.onDelete,
    required this.onOpenRelated,
    required this.loadImageBytes,
    required this.cachedImageBytes,
    this.layout,
    this.focusId,
    this.busy = false,
    this.progressMessage,
    this.imageGenerating = false,
    this.canEditImage = true,
    this.relationsPending = false,
  });

  final PlacedNode node;
  final GraphLayout? layout;
  final String? focusId;
  final bool busy;
  final String? progressMessage;
  final bool imageGenerating;
  final bool relationsPending;
  final bool showRelations;
  final bool canRequestNeighbors;
  final bool canViewInGraph;
  final bool canEditImage;
  final VoidCallback onClose;
  final VoidCallback onRequestNeighbors;
  final VoidCallback onViewInGraph;
  final VoidCallback onLearn;
  final VoidCallback onImageAction;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<PlacedNode> onOpenRelated;
  final Future<List<int>?> Function(String imageUrl) loadImageBytes;
  final Uint8List? Function(String? imageUrl) cachedImageBytes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final desc = (node.description ?? '').trim();
    final imageUrl = (node.imageUrl ?? '').trim();
    final hasImage = imageUrl.isNotEmpty;
    final bottomClearance = OverlayPanel.bottomClearance(context, hasBottom: false);

    return OverlayPanel(
      onDismiss: onClose,
      child: SafeArea(
        bottom: false,
        child: ListView(
          padding: studyPagePadding.copyWith(bottom: bottomClearance),
          children: [
            if (hasImage || imageGenerating) ...[
              _TopicHeroImage(
                key: ValueKey(node.id),
                imageUrl: hasImage ? imageUrl : null,
                cachedBytes: hasImage ? cachedImageBytes(imageUrl) : null,
                loading: imageGenerating,
                loadImageBytes: loadImageBytes,
              ),
              const SizedBox(height: 16),
            ],
            Text(
              node.title,
              style: TextStyle(
                fontFamily: 'tt_ramilas',
                fontWeight: FontWeight.w700,
                fontSize: 28,
                height: 1.15,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 12),
            if (desc.isNotEmpty)
              Text(
                desc,
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
            const SizedBox(height: 20),
            Row(
              children: [
                if (canRequestNeighbors) ...[
                  _TopicIconButton(
                    tooltip: 'Request neighbors',
                    icon: Icons.auto_awesome,
                    filled: true,
                    onPressed: onRequestNeighbors,
                  ),
                  const SizedBox(width: 8),
                ] else if (canViewInGraph) ...[
                  _TopicIconButton(
                    tooltip: 'View in graph',
                    icon: Icons.arrow_forward,
                    filled: true,
                    onPressed: onViewInGraph,
                  ),
                  const SizedBox(width: 8),
                ],
                _TopicIconButton(
                  tooltip: 'Learn',
                  icon: Icons.menu_book_outlined,
                  filled: !canRequestNeighbors && !canViewInGraph,
                  onPressed: onLearn,
                ),
                const SizedBox(width: 8),
                _TopicIconButton(
                  tooltip: hasImage ? 'Change image' : 'Add image',
                  icon: Icons.image_outlined,
                  onPressed: canEditImage ? onImageAction : null,
                ),
                const SizedBox(width: 8),
                _TopicIconButton(
                  tooltip: 'Edit',
                  icon: Icons.edit_outlined,
                  onPressed: onEdit,
                ),
                const SizedBox(width: 8),
                _TopicIconButton(
                  tooltip: 'Delete',
                  icon: Icons.delete_outline,
                  foreground: scheme.error,
                  onPressed: onDelete,
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (busy) ...[
              _TopicProgressCard(
                title: imageGenerating ? 'Updating image' : 'Building neighborhood',
                message: progressMessage ??
                    (imageGenerating ? 'Working on topic image…' : 'Loading related topics…'),
              ),
              if (showRelations || relationsPending) const SizedBox(height: 12),
            ],
            if (relationsPending)
              const SizedBox(
                height: 168,
                child: PulsePlaceholder(
                  borderRadius: BorderRadius.all(Radius.circular(16)),
                ),
              )
            else if (showRelations && layout != null)
              _RelationsCard(
                node: node,
                layout: layout!,
                focusId: focusId,
                onOpen: onOpenRelated,
              ),
          ],
        ),
      ),
    );
  }
}

class _TopicHeroImage extends StatefulWidget {
  const _TopicHeroImage({
    super.key,
    required this.loadImageBytes,
    this.imageUrl,
    this.cachedBytes,
    this.loading = false,
  });

  final String? imageUrl;
  final Uint8List? cachedBytes;
  final bool loading;
  final Future<List<int>?> Function(String imageUrl) loadImageBytes;

  @override
  State<_TopicHeroImage> createState() => _TopicHeroImageState();
}

class _TopicHeroImageState extends State<_TopicHeroImage> {
  Uint8List? _bytes;
  var _loadingBytes = false;
  String? _loadedUrl;
  var _loadGen = 0;

  @override
  void initState() {
    super.initState();
    _hydrateFromCache();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant _TopicHeroImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _hydrateFromCache();
      unawaited(_load());
      return;
    }
    if (_bytes == null && widget.cachedBytes != null && widget.cachedBytes!.isNotEmpty) {
      setState(_hydrateFromCache);
    }
  }

  void _hydrateFromCache() {
    final url = (widget.imageUrl ?? '').trim();
    final cached = widget.cachedBytes;
    if (url.isEmpty || cached == null || cached.isEmpty) return;
    _bytes = cached;
    _loadedUrl = url;
    _loadingBytes = false;
  }

  Future<void> _load() async {
    final url = (widget.imageUrl ?? '').trim();
    final gen = ++_loadGen;
    if (url.isEmpty) {
      if (mounted) {
        setState(() {
          _bytes = null;
          _loadedUrl = null;
          _loadingBytes = false;
        });
      }
      return;
    }
    if (url == _loadedUrl && _bytes != null) return;
    if (_bytes == null) {
      setState(() => _loadingBytes = true);
    }
    final bytes = await widget.loadImageBytes(url);
    if (!mounted || gen != _loadGen) return;
    if ((widget.imageUrl ?? '').trim() != url) return;
    if (bytes == null || bytes.isEmpty) {
      setState(() => _loadingBytes = false);
      return;
    }
    final next = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    if (url == _loadedUrl && _bytes != null && identical(_bytes, next)) {
      if (_loadingBytes) setState(() => _loadingBytes = false);
      return;
    }
    setState(() {
      _bytes = next;
      _loadedUrl = url;
      _loadingBytes = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(16));
    final bytes = _bytes;
    final showPlaceholder = bytes == null && (widget.loading || _loadingBytes);
    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: radius,
        child: showPlaceholder
            ? const PulsePlaceholder.image(borderRadius: radius)
            : Image.memory(
                bytes!,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
              ),
      ),
    );
  }
}

class _TopicProgressCard extends StatelessWidget {
  const _TopicProgressCard({
    required this.message,
    this.title = 'Building neighborhood',
  });

  final String title;
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
                    title,
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

class _TopicIconButton extends StatelessWidget {
  const _TopicIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.filled = false,
    this.foreground,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool filled;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final fg = (foreground ?? (filled ? scheme.onPrimary : scheme.onSurfaceVariant))
        .withValues(alpha: enabled ? 1 : 0.38);
    final bg = filled
        ? scheme.primary.withValues(alpha: enabled ? 1 : 0.38)
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
    required this.imageBytesFor,
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
  final Uint8List? Function(String? imageUrl) imageBytesFor;

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
                      imageBytes: widget.imageBytesFor(
                        (node.imageThumbUrl?.trim().isNotEmpty == true)
                            ? node.imageThumbUrl
                            : node.imageUrl,
                      ),
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
    this.imageBytes,
  });

  final PlacedNode node;
  final bool focused;
  final bool pending;
  final bool centerHighlight;
  final VoidCallback onTap;
  final Uint8List? imageBytes;

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
          imageBytes: imageBytes,
        );
        final bloom = _flowerCard(
          scheme: scheme,
          fill: base,
          dark: dark,
          spotlight: spotlight,
          imageBytes: imageBytes,
          contentOpacity: Curves.easeOut.transform(flower.clamp(0.0, 1.0)),
        );
        // Crossfade the whole range so flowerAmount never pops widgets in/out.
        final child = flower <= 0
            ? hex
            : flower >= 1
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
    Uint8List? imageBytes,
    double contentOpacity = 1,
  }) {
    final description = (node.description ?? '').trim();
    final hasImage = imageBytes != null;
    final titleColor = hasImage ? Colors.white : scheme.onSurface;
    final descColor = hasImage
        ? Colors.white.withValues(alpha: 0.88)
        : scheme.onSurface.withValues(alpha: 0.72);
    return CustomPaint(
      painter: _HexFlowerPainter(color: fill, dark: dark, spotlight: spotlight),
      child: Opacity(
        opacity: contentOpacity.clamp(0.0, 1.0),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (hasImage) _hexImageFill(imageBytes!, flower: true),
            if (hasImage)
              ClipPath(
                clipper: const _FlowerTapClipper(),
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x00000000),
                        Color(0x14000000),
                        Color(0x8A000000),
                      ],
                      stops: [0.35, 0.58, 1.0],
                    ),
                  ),
                ),
              ),
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: node.radius * 0.62,
                vertical: node.radius * 0.58,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final scaler = MediaQuery.textScalerOf(context);
                  final maxW = constraints.maxWidth;
                  final maxH = constraints.maxHeight;
                  if (maxW <= 1 || maxH <= 1) return const SizedBox.shrink();

                  final hasDesc = description.isNotEmpty;
                const titleMaxLines = 3;
                final titleStyleBase = TextStyle(
                  fontFamily: 'tt_ramilas',
                  height: 1.1,
                  fontWeight: FontWeight.w700,
                  color: titleColor,
                  shadows: hasImage ? _imageTitleShadows : null,
                );
                final titleBudget = hasDesc ? maxH * 0.42 : maxH * 0.92;
                final titleLaid = layoutTitle(
                  text: node.title,
                  style: titleStyleBase,
                  maxWidth: maxW,
                  maxHeight: titleBudget,
                  maxLines: titleMaxLines,
                  minFontSize: 13,
                  maxFontSize: (node.radius * 0.5).clamp(17.0, 34.0),
                  textScaler: scaler,
                  hyphenateAtMinSize: true,
                );
                final titleStyle = titleStyleBase.copyWith(fontSize: titleLaid.fontSize);
                final gap = (node.radius * 0.08).clamp(4.0, 10.0);
                final descStyle = TextStyle(
                  fontFamily: 'tt_ramilas',
                  height: 1.25,
                  fontWeight: FontWeight.w500,
                  color: descColor,
                  fontSize: (node.radius * 0.22).clamp(13.0, 18.0),
                  shadows: hasImage ? _imageBodyShadows : null,
                );

                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          titleLaid.text,
                          textAlign: TextAlign.center,
                          softWrap: true,
                          maxLines: titleMaxLines,
                          overflow: TextOverflow.ellipsis,
                          style: titleStyle,
                        ),
                        if (hasDesc) ...[
                          SizedBox(height: gap),
                          Text(
                            description,
                            textAlign: TextAlign.center,
                            softWrap: true,
                            maxLines: 5,
                            overflow: TextOverflow.ellipsis,
                            style: descStyle,
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tileCard({
    required ColorScheme scheme,
    required Color fill,
    required bool dark,
    required double spotlight,
    Uint8List? imageBytes,
  }) {
    final hasImage = imageBytes != null;
    return CustomPaint(
      painter: _HexTilePainter(color: fill, dark: dark, spotlight: spotlight),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hasImage) _hexImageFill(imageBytes!, flower: false),
          Padding(
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
                  fontWeight: FontWeight.w600,
                  color: hasImage ? Colors.white : scheme.onSurface.withValues(alpha: 0.9),
                  shadows: hasImage ? _imageTitleShadows : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static const _hexImageOpacity = 0.4;

  Widget _hexImageFill(Uint8List bytes, {required bool flower}) {
    return ClipPath(
      clipper: flower ? const _FlowerTapClipper() : const _HexTapClipper(),
      child: Opacity(
        opacity: _hexImageOpacity,
        child: Image.memory(
          bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
        ),
      ),
    );
  }
}

const _imageTitleShadows = <Shadow>[
  Shadow(color: Color(0xB3000000), blurRadius: 7, offset: Offset(0, 1)),
  Shadow(color: Color(0x80000000), blurRadius: 2, offset: Offset(0, 0.5)),
];

const _imageBodyShadows = <Shadow>[
  Shadow(color: Color(0x99000000), blurRadius: 5, offset: Offset(0, 1)),
];

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
