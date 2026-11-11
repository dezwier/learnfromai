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

class _GraphScreenState extends State<GraphScreen> with TickerProviderStateMixin {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _transform = TransformationController();
  String? _transformFocusId;
  Timer? _suggestDebounce;
  Offset? _searchOutsideDown;
  var _searchOutsideMoved = false;
  var _resumed = false;
  var _searchOpen = false;
  var _profileOpen = false;
  AnimationController? _camera;
  Animation<Matrix4>? _cameraAnim;

  @override
  void initState() {
    super.initState();
    _camera = AnimationController(vsync: this, duration: const Duration(milliseconds: 420))
      ..addListener(() {
        final anim = _cameraAnim;
        if (anim == null) return;
        _transform.value = anim.value;
      });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _resumed) return;
      _resumed = true;
      context.read<GraphController>().resume();
    });
  }

  @override
  void dispose() {
    _suggestDebounce?.cancel();
    _camera?.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _transform.dispose();
    super.dispose();
  }

  void _flyToFocusIfNeeded({
    required String? focusId,
    required GraphLayout layout,
    required Size viewport,
  }) {
    if (focusId == null || _transformFocusId == focusId) return;
    _transformFocusId = focusId;
    PlacedNode? target;
    for (final node in layout.nodes) {
      if (node.id == focusId) {
        target = node;
        break;
      }
    }
    final end = Matrix4.identity();
    if (target == null) {
      end.translateByDouble(
        (viewport.width - layout.width) / 2,
        (viewport.height - layout.height) / 2,
        0,
        1,
      );
    } else {
      final scale = _transform.value.getMaxScaleOnAxis().clamp(0.55, 2.4);
      final tx = viewport.width / 2 - target.center.dx * scale;
      final ty = viewport.height / 2 - target.center.dy * scale;
      end
        ..translateByDouble(tx, ty, 0, 1)
        ..scaleByDouble(scale, scale, scale, 1);
    }
    final cam = _camera;
    if (cam == null) {
      _transform.value = end;
      return;
    }
    _cameraAnim = Matrix4Tween(begin: _transform.value.clone(), end: end).animate(
      CurvedAnimation(parent: cam, curve: Curves.easeInOutCubic),
    );
    cam.forward(from: 0);
  }

  void _requestMapForViewport(GraphController graph, GraphLayout layout, Size viewport) {
    if (layout.nodes.isEmpty) return;
    Matrix4 inverse;
    try {
      inverse = Matrix4.inverted(_transform.value);
    } catch (_) {
      return;
    }
    final topLeft = MatrixUtils.transformPoint(inverse, Offset.zero);
    final bottomRight = MatrixUtils.transformPoint(
      inverse,
      Offset(viewport.width, viewport.height),
    );
    final radius = layout.nodes.first.radius;
    var qmin = 1 << 20;
    var qmax = -(1 << 20);
    var rmin = 1 << 20;
    var rmax = -(1 << 20);
    var any = false;
    for (final node in layout.nodes) {
      if (node.q == null || node.r == null) continue;
      final c = node.center;
      if (c.dx < topLeft.dx - radius * 2 ||
          c.dx > bottomRight.dx + radius * 2 ||
          c.dy < topLeft.dy - radius * 2 ||
          c.dy > bottomRight.dy + radius * 2) {
        continue;
      }
      any = true;
      qmin = math.min(qmin, node.q!);
      qmax = math.max(qmax, node.q!);
      rmin = math.min(rmin, node.r!);
      rmax = math.max(rmax, node.r!);
    }
    if (!any) {
      final topic = graph.worldById[graph.focusId];
      if (topic?.q != null && topic?.r != null) {
        qmin = topic!.q! - 5;
        qmax = topic.q! + 5;
        rmin = topic.r! - 5;
        rmax = topic.r! + 5;
      } else {
        return;
      }
    } else {
      qmin -= 3;
      qmax += 3;
      rmin -= 3;
      rmax += 3;
    }
    graph.fetchMap(qmin: qmin, qmax: qmax, rmin: rmin, rmax: rmax);
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
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      // Keep the graph still when the keyboard opens; search floats above it.
      resizeToAvoidBottomInset: false,
      floatingActionButton: (_searchOpen || _profileOpen)
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
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
          if (graph.working)
            Positioned(
              left: 16,
              bottom: 16 + keyboard,
              child: _ProgressChip(message: graph.progressMessage ?? 'Working…'),
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

  bool _hasNodes(GraphController graph) => graph.hasWorldNodes;

  Widget _body(BuildContext context, GraphController graph) {
    if (graph.loading && !graph.hasWorldNodes) {
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
            subtitle: 'Search a topic. The shared hex world grows around roots at the center.',
          ),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        final layout = _layoutFor(graph, viewport);
        _flyToFocusIfNeeded(
          focusId: graph.focusId,
          layout: layout,
          viewport: viewport,
        );
        return InteractiveViewer(
          transformationController: _transform,
          constrained: false,
          minScale: 0.45,
          maxScale: 3.5,
          boundaryMargin: const EdgeInsets.all(480),
          onInteractionEnd: (_) => _requestMapForViewport(graph, layout, viewport),
          child: SizedBox(
            width: layout.width,
            height: layout.height,
            child: _GraphView(
              layout: layout,
              focusId: graph.focusId,
              pendingId: graph.refreshing ? graph.pendingNodeId : null,
              transform: _transform,
              viewport: viewport,
              onOpen: graph.openNode,
            ),
          ),
        );
      },
    );
  }

  GraphLayout _layoutFor(GraphController graph, Size viewport) {
    final edges = [
      for (final raw in graph.worldEdges)
        GraphEdge(
          source: raw['source'] ?? '',
          target: raw['target'] ?? '',
          type: raw['type'] ?? 'related',
        ),
    ];
    final focus = graph.focusId;
    final nodes = [
      for (final topic in graph.worldTopics)
        if (topic.q != null && topic.r != null)
          GraphNode(
            id: topic.id,
            title: topic.title,
            depth: topic.depth,
            distance: topic.depth,
            kind: kindRelativeToFocus(nodeId: topic.id, focusId: focus, edges: edges),
            description: topic.description,
            q: topic.q,
            r: topic.r,
          ),
    ];
    if (nodes.isEmpty) {
      return GraphLayout(nodes: const [], width: viewport.width, height: viewport.height);
    }
    return layoutWorld(nodes, viewport: viewport);
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
    required this.pendingId,
    required this.transform,
    required this.viewport,
    required this.onOpen,
  });

  final GraphLayout layout;
  final String? focusId;
  final String? pendingId;
  final TransformationController transform;
  final Size viewport;
  final ValueChanged<String> onOpen;

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
  }

  @override
  Widget build(BuildContext context) {
    const shadowPad = 14.0;
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final node in widget.layout.nodes)
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
                  centerHighlight: node.id == _centerId,
                  onTap: () => widget.onOpen(node.id),
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
        : roleFill(node.role, scheme);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: (centerHighlight || focused) ? 1.0 : 0.0),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (context, spotlight, _) {
        // Equal hex world: selection is shadow/intensity only (no focus flower).
        final fill = focused ? base : _intensifyFill(base, spotlight, dark: dark);
        final scale = 1.0 + 0.045 * spotlight;
        final child = _tileCard(
          scheme: scheme,
          fill: fill,
          dark: dark,
          spotlight: focused ? math.max(spotlight, 0.85) : spotlight,
        );
        return GestureDetector(
          onTap: onTap,
          child: Transform.scale(
            scale: scale,
            child: child,
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
    required bool showDescription,
  }) {
    return CustomPaint(
      painter: _HexFlowerPainter(color: fill, dark: dark, spotlight: spotlight),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: node.radius * 0.58,
          vertical: node.radius * 0.95,
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
            final gap = node.radius * 0.06;
            final descPad = node.radius * 0.18;

            // Description keeps one fixed style; only line count adapts.
            final descFontSize = (node.radius * 0.28).clamp(13.0, 17.0);
            final descStyle = TextStyle(
              fontFamily: 'tt_ramilas',
              height: 1.28,
              fontWeight: FontWeight.w400,
              fontSize: descFontSize,
              color: scheme.onSurface.withValues(alpha: 0.72),
            );
            final descLineHeight = scaler.scale(descFontSize) * 1.28;

            // Keep air inside the hex so title+desc stay centered, not edge-hugging.
            final contentBudget = maxH * 0.88;
            final reserveDesc = showDescription ? gap + descLineHeight * 2 : 0.0;
            final titleMaxH = (contentBudget - reserveDesc).clamp(14.0, contentBudget);
            final titleLaid = layoutTitle(
              text: node.title,
              style: titleStyleBase,
              maxWidth: maxW,
              maxHeight: titleMaxH,
              maxLines: titleMaxLines,
              minFontSize: 12,
              maxFontSize: (node.radius * 0.5).clamp(18.0, 30.0),
              textScaler: scaler,
              hyphenateAtMinSize: true,
            );
            final titleStyle = titleStyleBase.copyWith(fontSize: titleLaid.fontSize);
            final titlePainter = TextPainter(
              text: TextSpan(text: titleLaid.text, style: titleStyle),
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.center,
              textScaler: scaler,
              maxLines: titleMaxLines,
            )..layout(maxWidth: maxW);

            final descMaxLines = showDescription
                ? ((contentBudget - titlePainter.height - gap) / descLineHeight)
                    .floor()
                    .clamp(1, 6)
                : 0;

            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    titleLaid.text,
                    textAlign: TextAlign.center,
                    softWrap: true,
                    maxLines: titleMaxLines,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                  if (showDescription && descMaxLines > 0) ...[
                    SizedBox(height: gap),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: descPad),
                      child: Text(
                        node.description!.trim(),
                        textAlign: TextAlign.center,
                        softWrap: true,
                        maxLines: descMaxLines,
                        overflow: TextOverflow.ellipsis,
                        style: descStyle,
                      ),
                    ),
                  ],
                ],
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

class _HexFlowerPainter extends CustomPainter {
  _HexFlowerPainter({required this.color, required this.dark, this.spotlight = 0});

  final Color color;
  final bool dark;
  final double spotlight;

  @override
  void paint(Canvas canvas, Size size) {
    final lattice = math.min(size.width / 5, size.height / (3 * math.sqrt(3)));
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
