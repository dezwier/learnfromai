import 'dart:async';
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
import 'title_wrap.dart';

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
  Timer? _suggestDebounce;
  Offset? _searchOutsideDown;
  var _searchOutsideMoved = false;
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
    _suggestDebounce?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _transform.dispose();
    super.dispose();
  }

  void _resetTransformIfFocusChanged({
    required String? focusId,
    required Size viewport,
    required Size canvas,
  }) {
    if (_transformFocusId == focusId) return;
    _transformFocusId = focusId;
    // Focus is laid out at the canvas center; translate so that lands in view.
    _transform.value = Matrix4.translationValues(
      (viewport.width - canvas.width) / 2,
      (viewport.height - canvas.height) / 2,
      0,
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
  }

  Future<void> _pickSuggestion(GraphController graph, TopicChoice choice) async {
    _search.clear();
    _dismissSearch();
    await graph.openExisting(choice.id);
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
          : Builder(
              builder: (context) {
                final scheme = Theme.of(context).colorScheme;
                return FloatingActionButton.small(
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
                );
              },
            ),
      bottomSheet: _searchOpen
          ? _SearchBar(
              controller: _search,
              focusNode: _searchFocus,
              suggestions: graph.suggestions,
              onChanged: (value) => _onSearchChanged(graph, value),
              onSubmit: () => _submitSearch(graph),
              onPick: (choice) => _pickSuggestion(graph, choice),
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
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        final layout = _layoutFor(graph, viewport);
        _resetTransformIfFocusChanged(
          focusId: graph.focusId,
          viewport: viewport,
          canvas: Size(layout.width, layout.height),
        );
        return InteractiveViewer(
          transformationController: _transform,
          constrained: false,
          minScale: 0.45,
          maxScale: 3.5,
          boundaryMargin: const EdgeInsets.all(480),
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
                        title: Text(choice.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: (subtitle == null || subtitle.isEmpty)
                            ? null
                            : Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
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
                        hyphenateWords: true,
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
                          maxLines: 5,
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
              hyphenateWords: true,
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
