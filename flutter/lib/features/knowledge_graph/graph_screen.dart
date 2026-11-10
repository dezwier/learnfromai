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
  final _searchFocus = FocusNode();
  final _transform = TransformationController();
  String? _transformFocusId;
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

  void _resetTransformIfFocusChanged(String? focusId) {
    if (_transformFocusId == focusId) return;
    _transformFocusId = focusId;
    _transform.value = Matrix4.identity();
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

  Future<void> _openPrefs(GraphController graph) async {
    var draft = graph.prefs;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheet) {
            Widget stepper(String label, int value, int min, int max, ValueChanged<int> onChanged) {
              return ListTile(
                title: Text(label),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      onPressed: value > min ? () => setSheet(() => onChanged(value - 1)) : null,
                      icon: const Icon(Icons.remove),
                    ),
                    Text('$value'),
                    IconButton(
                      onPressed: value < max ? () => setSheet(() => onChanged(value + 1)) : null,
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
              );
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const ListTile(
                      title: Text('Neighborhood size'),
                      subtitle: Text('How many related topics to fetch around a focus.'),
                    ),
                    stepper('Parents', draft.parents, 1, 2, (value) => draft = draft.copyWith(parents: value)),
                    stepper('Siblings', draft.siblings, 2, 3, (value) => draft = draft.copyWith(siblings: value)),
                    stepper('Children', draft.children, 3, 5, (value) => draft = draft.copyWith(children: value)),
                    stepper(
                      'Related',
                      draft.acquaintances,
                      3,
                      5,
                      (value) => draft = draft.copyWith(acquaintances: value),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: FilledButton(
                        onPressed: () async {
                          Navigator.of(context).pop();
                          await graph.savePreferences(draft);
                        },
                        child: const Text('Save'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final graph = context.watch<GraphController>();
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
            tooltip: 'Neighborhood settings',
            onPressed: () => _openPrefs(graph),
            icon: const Icon(Icons.tune),
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
      floatingActionButton: _searchOpen
          ? null
          : FloatingActionButton(
              heroTag: 'graph-search',
              tooltip: 'Search',
              onPressed: _openSearch,
              child: const Icon(Icons.search),
            ),
      bottomSheet: _searchOpen
          ? _SearchBar(
              controller: _search,
              focusNode: _searchFocus,
              onSubmit: () => _submitSearch(graph),
              onDismiss: _dismissSearch,
            )
          : null,
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
              Expanded(child: _body(context, graph)),
            ],
          ),
          if (graph.working)
            Positioned(
              left: 16,
              bottom: 16 + MediaQuery.viewInsetsOf(context).bottom,
              child: _ProgressChip(message: graph.progressMessage ?? 'Working…'),
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
        _resetTransformIfFocusChanged(graph.focusId);
        final layout = _layoutFor(graph, Size(constraints.maxWidth, constraints.maxHeight));
        return InteractiveViewer(
          transformationController: _transform,
          constrained: false,
          minScale: 0.45,
          maxScale: 3.5,
          boundaryMargin: const EdgeInsets.all(300),
          child: SizedBox(
            width: layout.width,
            height: layout.height,
            child: _GraphView(
              layout: layout,
              focusId: graph.focusId,
              pendingId: graph.refreshing ? graph.pendingNodeId : null,
              onOpen: graph.openNode,
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
    return layoutGraph(nodes, edges, focusId: focus, viewport: viewport);
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
    required this.onSubmit,
    required this.onDismiss,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSubmit;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 8,
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(
            children: [
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
      ),
    );
  }
}

class _GraphView extends StatelessWidget {
  const _GraphView({
    required this.layout,
    required this.focusId,
    required this.pendingId,
    required this.onOpen,
  });

  final GraphLayout layout;
  final String? focusId;
  final String? pendingId;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    const shadowPad = 10.0;
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final node in layout.nodes)
            Positioned(
              left: node.x - shadowPad,
              top: node.y - shadowPad,
              width: node.width + shadowPad * 2,
              height: node.height + shadowPad * 2,
              child: Padding(
                padding: const EdgeInsets.all(shadowPad),
                child: _NodeCard(
                  node: node,
                  focused: node.id == focusId,
                  pending: node.id == pendingId,
                  onTap: () => onOpen(node.id),
                ),
              ),
            ),
        ],
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
    final fill = pending ? const Color(0xFFDDE7F4) : roleFill(node.role, scheme);
    final dark = scheme.brightness == Brightness.dark;
    final showDescription = node.isFlower && (node.description ?? '').trim().isNotEmpty;
    if (node.isFlower) {
      return GestureDetector(
        onTap: onTap,
        child: CustomPaint(
          painter: _HexFlowerPainter(color: fill, dark: dark),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: node.radius * 0.55,
              vertical: node.radius * 0.7,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final titleBudget =
                    showDescription ? constraints.maxHeight * 0.26 : constraints.maxHeight;
                final descBudget = constraints.maxHeight * 0.64;
                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: titleBudget,
                      child: _FittingLabel(
                        text: node.title,
                        maxLines: 3,
                        minFontSize: 12,
                        maxFontSize: (node.radius * 0.5).clamp(18.0, 30.0),
                        align: Alignment.bottomCenter,
                        style: TextStyle(
                          height: 1.1,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                    if (showDescription) ...[
                      SizedBox(height: node.radius * 0.03),
                      SizedBox(
                        height: descBudget,
                        child: _FittingLabel(
                          text: node.description!.trim(),
                          maxLines: 12,
                          minFontSize: 10,
                          maxFontSize: (node.radius * 0.34).clamp(13.0, 20.0),
                          align: Alignment.topCenter,
                          style: TextStyle(
                            height: 1.28,
                            fontWeight: FontWeight.w400,
                            color: scheme.onSurface.withValues(alpha: 0.72),
                          ),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: onTap,
      child: CustomPaint(
        painter: _HexTilePainter(color: fill, dark: dark),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: node.radius * 0.34,
            vertical: node.radius * 0.24,
          ),
          child: Center(
            child: _FittingLabel(
              text: node.title,
              maxLines: 4,
              minFontSize: 8,
              maxFontSize: (node.radius * 0.32).clamp(11.0, 17.0),
              style: TextStyle(
                height: 1.15,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface.withValues(alpha: 0.9),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Scales font to the tile. Wraps only between words; never mid-word.
class _FittingLabel extends StatelessWidget {
  const _FittingLabel({
    required this.text,
    required this.style,
    required this.maxLines,
    required this.minFontSize,
    required this.maxFontSize,
    this.align = Alignment.center,
  });

  final String text;
  final TextStyle style;
  final int maxLines;
  final double minFontSize;
  final double maxFontSize;
  final Alignment align;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Keep a margin so painted glyphs never force a mid-word break.
        final maxWidth = (constraints.maxWidth - 2).clamp(0.0, double.infinity);
        final maxHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : maxWidth * 2;
        if (maxWidth <= 1 || text.trim().isEmpty) {
          return const SizedBox.shrink();
        }
        final fontSize = _fitFontSize(
          text: text,
          style: style,
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          maxLines: maxLines,
          minSize: minFontSize,
          maxSize: maxFontSize,
          textScaler: scaler,
        );
        return SizedBox.expand(
          child: Align(
            alignment: align,
            child: Text(
              text,
              textAlign: TextAlign.center,
              softWrap: true,
              maxLines: maxLines,
              overflow: TextOverflow.clip,
              style: style.copyWith(fontSize: fontSize),
            ),
          ),
        );
      },
    );
  }
}

double _fitFontSize({
  required String text,
  required TextStyle style,
  required double maxWidth,
  required double maxHeight,
  required int maxLines,
  required double minSize,
  required double maxSize,
  required TextScaler textScaler,
}) {
  final words = [
    for (final w in text.split(RegExp(r'\s+')))
      if (w.isNotEmpty) w,
  ];
  if (words.isEmpty) return minSize;

  var lo = minSize;
  var hi = maxSize;
  var best = minSize;
  for (var i = 0; i < 16; i++) {
    final mid = (lo + hi) / 2;
    if (_textFits(
      text: text,
      words: words,
      style: style.copyWith(fontSize: mid),
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      maxLines: maxLines,
      textScaler: textScaler,
    )) {
      best = mid;
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return best;
}

bool _textFits({
  required String text,
  required List<String> words,
  required TextStyle style,
  required double maxWidth,
  required double maxHeight,
  required int maxLines,
  required TextScaler textScaler,
}) {
  // Safety margin vs measurement vs paint differences (esp. with custom fonts).
  final wordLimit = maxWidth * 0.96;
  for (final word in words) {
    final wordPainter = TextPainter(
      text: TextSpan(text: word, style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    if (wordPainter.width > wordLimit) return false;
  }

  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.center,
    textScaler: textScaler,
    maxLines: maxLines,
  )..layout(maxWidth: maxWidth);
  if (painter.didExceedMaxLines) return false;
  if (painter.height > maxHeight + 0.5) return false;
  for (final metric in painter.computeLineMetrics()) {
    if (metric.width > maxWidth + 0.5) return false;
  }
  return true;
}

void _paintHexDepth(Canvas canvas, Path path, Color color, {required bool dark}) {
  if (dark) {
    // Very soft white lift — just enough to read on dark backgrounds.
    canvas.drawShadow(path, Colors.white.withValues(alpha: 0.18), 4, false);
  } else {
    canvas.drawShadow(path, const Color(0xFF000000), 5, true);
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
  _HexFlowerPainter({required this.color, required this.dark});

  final Color color;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final lattice = math.min(size.width / 5, size.height / (3 * math.sqrt(3)));
    final path = hexFlowerPath(
      latticeSize: lattice,
      center: Offset(size.width / 2, size.height / 2),
    );
    _paintHexDepth(canvas, path, color, dark: dark);
  }

  @override
  bool shouldRepaint(covariant _HexFlowerPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.dark != dark;
}

class _HexTilePainter extends CustomPainter {
  _HexTilePainter({required this.color, required this.dark});

  final Color color;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final lattice = math.min(size.width / 2, size.height / math.sqrt(3));
    final path = flatHexPath(
      lattice * (1 - hexGapInset),
      center: Offset(size.width / 2, size.height / 2),
    );
    _paintHexDepth(canvas, path, color, dark: dark);
  }

  @override
  bool shouldRepaint(covariant _HexTilePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.dark != dark;
}
