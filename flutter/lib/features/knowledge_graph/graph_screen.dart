import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/media/image_pick.dart';
import '../../core/widgets/pulse_placeholder.dart';
import '../../core/widgets/study_card.dart';
import '../profile/profile_hud.dart';
import '../profile/profile_screen.dart';
import 'graph_controller.dart';
import 'layout/graph_layout.dart';
import 'ui/focus_trail_bar.dart';
import 'ui/graph_view.dart';
import 'ui/jobs_chrome.dart';
import 'ui/learn_sheet.dart';
import 'ui/search_bar.dart';
import 'ui/topic_detail.dart';

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
  /// Trail shown in chrome; held steady until morph starts so chips don't pop early.
  List<FocusTrailEntry> _trailShown = const [];
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
    _trailShown = List.of(context.read<GraphController>().focusTrail);
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
      // Reveal the new trail chip with the morph, not on the network frame before it.
      _trailShown = List.of(context.read<GraphController>().focusTrail);
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
      _trailShown = List.of(context.read<GraphController>().focusTrail);
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
        _profileOpen = false;
      });
      _openTopicOverlay(source: 'graph');
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
    final wasTopicOpen = _topicOpen;
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
      if (wasTopicOpen && mounted) {
        _openTopicOverlay(source: 'list');
      }
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
      if (!mounted) return;
      if (!ok) {
        final message = graph.error ?? 'Image upload failed';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
        return;
      }
      final urls = _imageUrlsFromGraph(graph, node.id);
      setState(
        () => _highlighted = node.copyWith(
          imageUrl: urls.$1,
          imageThumbUrl: urls.$2,
        ),
      );
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

  /// Opens the topic detail overlay and records an `open` interaction.
  void _openTopicOverlay({required String source}) {
    final node = _highlighted;
    if (node == null) return;
    final graph = context.read<GraphController>();
    if (!_topicOpen || _profileOpen) {
      setState(() {
        _topicOpen = true;
        _profileOpen = false;
      });
    }
    unawaited(
      graph.trackEvent(
        nodeId: node.id,
        kind: 'open',
        payload: {'source': source},
      ),
    );
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
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _syncHighlightedFromLayout(graph.focusId);
    _openTopicOverlay(source: 'search');
  }

  Future<void> _pickSuggestion(GraphController graph, TopicChoice choice) async {
    _search.clear();
    _dismissSearch();
    await graph.openExisting(choice.id);
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _syncHighlightedFromLayout(graph.focusId);
    _openTopicOverlay(source: 'search');
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

  Future<void> _openTopicFromProfile(String nodeId) async {
    _closeProfile();
    final graph = context.read<GraphController>();
    await graph.openExisting(nodeId);
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _syncHighlightedFromLayout(graph.focusId ?? nodeId);
    _openTopicOverlay(source: 'graph');
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
    final liveTrail = graph.focusTrail;
    // Hold the previous trail until morph begins (avoids a pop on the fetch frame).
    final trail = (_pendingFocusMorph && _trailShown.isNotEmpty) ? _trailShown : liveTrail;
    if (!_pendingFocusMorph && !_layoutMorph.isAnimating && _morphFrom == null) {
      _trailShown = liveTrail;
    }
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
                        JobsPanel(
                          jobs: graph.trackedJobs.where((j) => j.isActive).toList(),
                          onSelect: (job) {
                            setState(() => _jobsPanelOpen = false);
                            unawaited(_openTrackedJob(graph, job));
                          },
                        ),
                        const SizedBox(height: 6),
                      ],
                      if (graph.hasActiveJobs)
                        JobsBadgeButton(
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
                  child: FocusTrailBar(
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
              child: GraphSearchBar(
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
              child: ProfileScreen(
                onClose: _closeProfile,
                onOpenTopic: (id) => unawaited(_openTopicFromProfile(id)),
              ),
            ),
          if (_topicOpen && _highlighted != null)
            Positioned.fill(
              child: TopicDetailScreen(
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
        // Cold start only: blank until the first camera snap. After that, keep
        // painting through pending adopt / morph — swapping to ColoredBox on
        // every focus change was the hop flicker.
        final cameraReady =
            !viewport.isEmpty && _settledLayout != null && _transformFocusId != null;
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
            child: GraphView(
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
    return layoutFromPayload(
      graph.categoryGraph,
      focusId: graph.focusId,
      viewport: viewport,
      maxExtended: graph.prefs.extended,
    );
  }
}

