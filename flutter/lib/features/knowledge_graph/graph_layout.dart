/// Hierarchical placement: parents above the focus, children below.
class HierarchyNode {
  const HierarchyNode({required this.id, required this.title, required this.depth});

  final int id;
  final String title;
  final int depth;
}

class HierarchyEdge {
  const HierarchyEdge({required this.source, required this.target});

  final int source;
  final int target;
}

class PlacedCategory {
  const PlacedCategory({required this.id, required this.title, required this.depth, required this.dx, required this.dy});

  final int id;
  final String title;
  final int depth;
  final double dx;
  final double dy;
}

class ShowMoreAnchor {
  const ShowMoreAnchor({required this.parentId, required this.dx, required this.dy, required this.hidden});

  final int parentId;
  final double dx;
  final double dy;
  final int hidden;
}

class HierarchyLayout {
  const HierarchyLayout({
    required this.nodes,
    required this.edges,
    required this.anchors,
    required this.width,
    required this.height,
  });

  final List<PlacedCategory> nodes;
  final List<HierarchyEdge> edges;
  final List<ShowMoreAnchor> anchors;
  final double width;
  final double height;
}

const hierarchyNodeWidth = 148.0;
const hierarchyNodeHeight = 64.0;
const hierarchyChildLimit = 6;

const _gapX = 20.0;
const _gapY = 56.0;
const _margin = 28.0;

HierarchyLayout layoutHierarchy(
  List<HierarchyNode> nodes,
  List<HierarchyEdge> edges, {
  Set<int> expanded = const {},
  int childLimit = hierarchyChildLimit,
}) {
  if (nodes.isEmpty) {
    return const HierarchyLayout(nodes: [], edges: [], anchors: [], width: 0, height: 0);
  }
  final byId = {for (final node in nodes) node.id: node};
  final children = <int, List<HierarchyNode>>{};
  for (final edge in edges) {
    final parent = byId[edge.source];
    final child = byId[edge.target];
    if (parent == null || child == null || child.depth != parent.depth + 1) continue;
    children.putIfAbsent(parent.id, () => []).add(child);
  }
  for (final list in children.values) {
    list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }

  final minDepth = nodes.map((node) => node.depth).reduce((a, b) => a < b ? a : b);
  final maxDepth = nodes.map((node) => node.depth).reduce((a, b) => a > b ? a : b);
  final visible = <int>{};
  for (var depth = minDepth; depth <= maxDepth; depth++) {
    for (final node in nodes.where((item) => item.depth == depth)) {
      if (depth <= 0) {
        visible.add(node.id);
        continue;
      }
      final parents = edges.where((edge) => edge.target == node.id && visible.contains(edge.source));
      for (final edge in parents) {
        final siblings = children[edge.source] ?? const <HierarchyNode>[];
        final index = siblings.indexWhere((sibling) => sibling.id == node.id);
        if (index != -1 && (expanded.contains(edge.source) || index < childLimit)) {
          visible.add(node.id);
          break;
        }
      }
    }
  }

  final layers = <int, List<HierarchyNode>>{};
  for (final node in nodes) {
    if (!visible.contains(node.id)) continue;
    layers.putIfAbsent(node.depth, () => []).add(node);
  }
  for (final list in layers.values) {
    list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }
  for (var pass = 0; pass < 4; pass++) {
    for (var depth = minDepth + 1; depth <= maxDepth; depth++) {
      _orderLayer(layers, edges, byId, depth, towardParent: true);
    }
    for (var depth = maxDepth - 1; depth >= minDepth; depth--) {
      _orderLayer(layers, edges, byId, depth, towardParent: false);
    }
  }

  var widest = 0.0;
  final widths = <int, double>{};
  for (final entry in layers.entries) {
    final count = entry.value.length;
    final width = count * hierarchyNodeWidth + (count - 1) * _gapX;
    widths[entry.key] = width;
    if (width > widest) widest = width;
  }
  final placed = <PlacedCategory>[];
  for (final depth in layers.keys.toList()..sort()) {
    final row = layers[depth]!;
    final rowWidth = widths[depth]!;
    final left = _margin + (widest - rowWidth) / 2;
    final top = _margin + (depth - minDepth) * (hierarchyNodeHeight + _gapY);
    for (var index = 0; index < row.length; index++) {
      final node = row[index];
      placed.add(
        PlacedCategory(
          id: node.id,
          title: node.title,
          depth: node.depth,
          dx: left + index * (hierarchyNodeWidth + _gapX),
          dy: top,
        ),
      );
    }
  }

  final anchors = <ShowMoreAnchor>[];
  for (final node in placed) {
    final kids = children[node.id] ?? const <HierarchyNode>[];
    if (kids.length <= childLimit || expanded.contains(node.id)) continue;
    anchors.add(
      ShowMoreAnchor(
        parentId: node.id,
        dx: node.dx + hierarchyNodeWidth / 2 - 40,
        dy: node.dy + hierarchyNodeHeight + 6,
        hidden: kids.length - childLimit,
      ),
    );
  }
  final visibleIds = {for (final node in placed) node.id};
  final visibleEdges = [
    for (final edge in edges)
      if (visibleIds.contains(edge.source) && visibleIds.contains(edge.target)) edge,
  ];
  var height = placed.isEmpty
      ? 0.0
      : placed.map((node) => node.dy).reduce((a, b) => a > b ? a : b) + hierarchyNodeHeight + _margin;
  for (final anchor in anchors) {
    final bottom = anchor.dy + 36;
    if (bottom > height) height = bottom;
  }
  return HierarchyLayout(
    nodes: placed,
    edges: visibleEdges,
    anchors: anchors,
    width: widest + _margin * 2,
    height: height,
  );
}

void _orderLayer(
  Map<int, List<HierarchyNode>> layers,
  List<HierarchyEdge> edges,
  Map<int, HierarchyNode> byId,
  int depth, {
  required bool towardParent,
}) {
  final list = layers[depth];
  if (list == null || list.length < 2) return;
  final neighborDepth = towardParent ? depth - 1 : depth + 1;
  final neighbors = layers[neighborDepth];
  if (neighbors == null) return;
  final indexOf = {for (var index = 0; index < neighbors.length; index++) neighbors[index].id: index};
  double barycenter(HierarchyNode node) {
    final related = towardParent
        ? edges.where((edge) => edge.target == node.id && indexOf.containsKey(edge.source))
        : edges.where((edge) => edge.source == node.id && indexOf.containsKey(edge.target) && byId[edge.target]?.depth == neighborDepth);
    final values = [
      for (final edge in related) indexOf[towardParent ? edge.source : edge.target]!,
    ];
    if (values.isEmpty) {
      return list.indexWhere((item) => item.id == node.id).toDouble();
    }
    return values.reduce((a, b) => a + b) / values.length;
  }

  final keyed = [for (final node in list) (barycenter(node), node.title.toLowerCase(), node)];
  keyed.sort((a, b) {
    final byCenter = a.$1.compareTo(b.$1);
    if (byCenter != 0) return byCenter;
    return a.$2.compareTo(b.$2);
  });
  layers[depth] = [for (final item in keyed) item.$3];
}
