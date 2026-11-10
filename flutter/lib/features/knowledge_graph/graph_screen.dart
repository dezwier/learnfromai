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
        final layout = _layoutFor(graph, Size(constraints.maxWidth, constraints.maxHeight));
        return _GraphView(
          layout: layout,
          focusId: graph.focusId,
          pendingId: graph.refreshing ? graph.pendingNodeId : null,
          onOpen: graph.openNode,
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
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Stack(
        children: [
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
    final showDescription = node.isFlower && (node.description ?? '').trim().isNotEmpty;
    final ShapeBorder shape = node.isFlower ? const HexFlowerBorder() : const HexagonBorder();
    return Material(
      color: fill,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        customBorder: shape,
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: node.isFlower ? node.radius * 1.1 : node.radius * 0.22,
            vertical: node.isFlower ? node.radius * 0.85 : node.radius * 0.18,
          ),
          child: node.isFlower
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      node.title,
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: (node.radius * 0.55).clamp(18.0, 28.0),
                        height: 1.15,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                    if (showDescription) ...[
                      const SizedBox(height: 10),
                      Flexible(
                        child: Text(
                          node.description!.trim(),
                          textAlign: TextAlign.center,
                          maxLines: 8,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: (node.radius * 0.28).clamp(12.0, 16.0),
                            height: 1.3,
                            fontWeight: FontWeight.w400,
                            color: scheme.onSurface.withValues(alpha: 0.72),
                          ),
                        ),
                      ),
                    ],
                  ],
                )
              : Center(
                  child: Text(
                    node.title,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: (node.radius * 0.28).clamp(11.0, 15.0),
                      height: 1.2,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface.withValues(alpha: 0.88),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}
