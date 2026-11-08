import 'package:flutter/material.dart';

/// An expandable tree. Contains-edges are the nesting; other nodes sit at the root.
class TopicTree extends StatefulWidget {
  const TopicTree({super.key, required this.nodes, required this.edges, required this.onOpen});

  final List<Map<String, dynamic>> nodes;
  final List<Map<String, dynamic>> edges;
  final ValueChanged<Map<String, dynamic>> onOpen;

  @override
  State<TopicTree> createState() => _TopicTreeState();
}

class _Branch {
  _Branch(this.node);

  final Map<String, dynamic> node;
  final List<_Branch> children = [];

  String get id => node['concept_id'].toString();
}

class _TopicTreeState extends State<TopicTree> {
  final _open = <String, bool>{};

  @override
  Widget build(BuildContext context) {
    final forest = _forest(widget.nodes, widget.edges);
    for (final branch in forest) {
      _open.putIfAbsent(branch.id, () => true);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
      children: [for (final branch in forest) _node(context, branch, 0)],
    );
  }

  Widget _node(BuildContext context, _Branch branch, int depth) {
    final open = _open[branch.id] ?? false;
    final ink = Theme.of(context).colorScheme.onSurface;
    final hasChildren = branch.children.isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(left: depth == 0 ? 0 : 16),
      child: DecoratedBox(
        decoration: depth == 0
            ? const BoxDecoration()
            : BoxDecoration(border: Border(left: BorderSide(color: const Color(0xFF1F4B6E).withValues(alpha: 0.28)))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: Color.alphaBlend(const Color(0xFF1F4B6E).withValues(alpha: 0.1), Theme.of(context).colorScheme.surface),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: const Color(0xFF1F4B6E).withValues(alpha: 0.35)),
                ),
                child: Row(
                  children: [
                    if (hasChildren)
                      IconButton(
                        tooltip: open ? 'Hide parts' : 'Show parts',
                        onPressed: () => setState(() => _open[branch.id] = !open),
                        icon: Icon(open ? Icons.expand_more : Icons.chevron_right),
                      )
                    else
                      const SizedBox(width: 16),
                    Expanded(
                      child: InkWell(
                        onTap: () => widget.onOpen(branch.node),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(0, 12, 12, 12),
                          child: Text(
                            branch.node['title']?.toString() ?? 'Concept',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, height: 1.25, color: ink),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: open && hasChildren
                  ? Column(children: [for (final child in branch.children) _node(context, child, depth + 1)])
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

List<_Branch> _forest(List<Map<String, dynamic>> nodes, List<Map<String, dynamic>> edges) {
  final byId = <String, _Branch>{};
  for (final node in nodes) {
    final id = node['concept_id']?.toString();
    if (id == null || id.isEmpty) continue;
    byId.putIfAbsent(id, () => _Branch(node));
  }
  final childIds = <String>{};
  for (final edge in edges) {
    if (edge['type']?.toString() != 'contains') continue;
    final parent = byId[edge['from_concept_id']?.toString()];
    final child = byId[edge['to_concept_id']?.toString()];
    if (parent == null || child == null || parent.id == child.id || childIds.contains(child.id)) continue;
    parent.children.add(child);
    childIds.add(child.id);
  }
  final roots = [for (final branch in byId.values) if (!childIds.contains(branch.id)) branch];
  int levelOf(_Branch branch) {
    final raw = branch.node['level'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse('$raw') ?? 0;
  }

  int compare(_Branch a, _Branch b) {
    final byLevel = levelOf(a).compareTo(levelOf(b));
    if (byLevel != 0) return byLevel;
    return (a.node['title']?.toString() ?? '').compareTo(b.node['title']?.toString() ?? '');
  }

  void sortBranch(_Branch branch) {
    branch.children.sort(compare);
    for (final child in branch.children) {
      sortBranch(child);
    }
  }

  roots.sort(compare);
  for (final root in roots) {
    sortBranch(root);
  }
  return roots;
}
