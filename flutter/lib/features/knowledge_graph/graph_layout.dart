import 'dart:math' as math;

import 'package:flutter/material.dart';

enum NodeRole { parent, focus, child, related }

class GraphNode {
  const GraphNode({
    required this.id,
    required this.title,
    required this.depth,
    this.distance = 0,
    this.kind = 'focus',
  });

  final int id;
  final String title;
  final int depth;
  final int distance;
  final String kind;

  NodeRole get role {
    switch (kind) {
      case 'parent':
        return NodeRole.parent;
      case 'child':
        return NodeRole.child;
      case 'related':
        return NodeRole.related;
      default:
        if (depth < 0) return NodeRole.parent;
        if (depth > 0) return NodeRole.child;
        return NodeRole.focus;
    }
  }
}

class GraphEdge {
  const GraphEdge({required this.source, required this.target, this.type = 'subclass_of'});

  final int source;
  final int target;
  final String type;

  bool get isRelated => type == 'related_to';
  bool get isHierarchy => type == 'subclass_of' || type == 'parent_taxon';
}

class PlacedNode {
  const PlacedNode({
    required this.id,
    required this.title,
    required this.depth,
    required this.distance,
    required this.kind,
    required this.role,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int id;
  final String title;
  final int depth;
  final int distance;
  final String kind;
  final NodeRole role;
  final double x;
  final double y;
  final double width;
  final double height;

  Offset get center => Offset(x + width / 2, y + height / 2);

  bool contains(Offset point) {
    return point.dx >= x && point.dx <= x + width && point.dy >= y && point.dy <= y + height;
  }
}

class GraphLayout {
  const GraphLayout({
    required this.nodes,
    required this.edges,
    required this.width,
    required this.height,
  });

  final List<PlacedNode> nodes;
  final List<GraphEdge> edges;
  final double width;
  final double height;
}

const graphCardWidth = 148.0;
const graphCardHeight = 52.0;
const graphGapX = 20.0;
const graphGapY = 88.0;
const graphSideGap = 56.0;
const graphPadding = 64.0;

/// Neighborhood graph: parents above, focus center, children below, related on the sides.
GraphLayout layoutGraph(
  List<GraphNode> nodes,
  List<GraphEdge> edges, {
  required int focusId,
}) {
  final byId = {for (final node in nodes) node.id: node};
  final parents = [
    for (final node in nodes)
      if (node.role == NodeRole.parent) node,
  ]..sort((a, b) => a.depth.compareTo(b.depth));
  final children = [
    for (final node in nodes)
      if (node.role == NodeRole.child) node,
  ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  final related = [
    for (final node in nodes)
      if (node.role == NodeRole.related) node,
  ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

  GraphNode? focus = byId[focusId];
  if (focus == null) {
    for (final node in nodes) {
      if (node.role == NodeRole.focus) {
        focus = node;
        break;
      }
    }
  }
  focus ??= nodes.isEmpty ? null : nodes.first;

  final parentWidth = _rowWidth(parents.length);
  final childWidth = _rowWidth(children.length);
  final leftRelated = [
    for (var i = 0; i < related.length; i += 2) related[i],
  ];
  final rightRelated = [
    for (var i = 1; i < related.length; i += 2) related[i],
  ];
  final sideWidth = math.max(_columnWidth(leftRelated.length), _columnWidth(rightRelated.length));
  final centerBand = math.max(graphCardWidth, math.max(parentWidth, childWidth));
  final width = math.max(
    graphPadding * 2 + sideWidth + graphSideGap + centerBand + graphSideGap + sideWidth,
    360.0,
  );

  final placed = <PlacedNode>[];
  var y = graphPadding;

  if (parents.isNotEmpty) {
    placed.addAll(_placeRow(parents, y: y, canvasWidth: width));
    y += graphCardHeight + graphGapY;
  }

  final focusY = y;
  if (focus != null) {
    placed.add(
      _card(
        focus,
        x: (width - graphCardWidth) / 2,
        y: focusY,
      ),
    );
  }

  // Related neighbors flank the focus.
  if (leftRelated.isNotEmpty) {
    final columnHeight = _columnHeight(leftRelated.length);
    final top = focusY + (graphCardHeight - columnHeight) / 2;
    placed.addAll(
      _placeColumn(
        leftRelated,
        x: graphPadding + (sideWidth - graphCardWidth).clamp(0, sideWidth) / 2,
        top: top,
      ),
    );
  }
  if (rightRelated.isNotEmpty) {
    final columnHeight = _columnHeight(rightRelated.length);
    final top = focusY + (graphCardHeight - columnHeight) / 2;
    placed.addAll(
      _placeColumn(
        rightRelated,
        x: width - graphPadding - sideWidth + (sideWidth - graphCardWidth).clamp(0, sideWidth) / 2,
        top: top,
      ),
    );
  }

  y = focusY + graphCardHeight + graphGapY;
  if (children.isNotEmpty) {
    placed.addAll(_placeRow(children, y: y, canvasWidth: width));
    y += graphCardHeight;
  } else {
    y = focusY + graphCardHeight;
  }

  final visibleIds = {for (final node in placed) node.id};
  final visibleEdges = [
    for (final edge in edges)
      if (visibleIds.contains(edge.source) && visibleIds.contains(edge.target)) edge,
  ];

  return GraphLayout(
    nodes: placed,
    edges: visibleEdges,
    width: width,
    height: math.max(y + graphPadding, 280.0),
  );
}

double _rowWidth(int count) {
  if (count <= 0) return 0;
  return count * graphCardWidth + math.max(0, count - 1) * graphGapX;
}

double _columnWidth(int count) => count <= 0 ? 0 : graphCardWidth;

double _columnHeight(int count) {
  if (count <= 0) return 0;
  return count * graphCardHeight + math.max(0, count - 1) * (graphGapX * 0.8);
}

List<PlacedNode> _placeRow(List<GraphNode> row, {required double y, required double canvasWidth}) {
  final bandWidth = _rowWidth(row.length);
  var x = (canvasWidth - bandWidth) / 2;
  return [
    for (final node in row)
      () {
        final card = _card(node, x: x, y: y);
        x += graphCardWidth + graphGapX;
        return card;
      }(),
  ];
}

List<PlacedNode> _placeColumn(List<GraphNode> column, {required double x, required double top}) {
  var y = top;
  return [
    for (final node in column)
      () {
        final card = _card(node, x: x, y: y);
        y += graphCardHeight + graphGapX * 0.8;
        return card;
      }(),
  ];
}

PlacedNode _card(GraphNode node, {required double x, required double y}) {
  return PlacedNode(
    id: node.id,
    title: node.title,
    depth: node.depth,
    distance: node.distance,
    kind: node.kind,
    role: node.role,
    x: x,
    y: y,
    width: graphCardWidth,
    height: graphCardHeight,
  );
}

int? hitTestNode(GraphLayout layout, Offset point) {
  for (final node in layout.nodes.reversed) {
    if (node.contains(point)) return node.id;
  }
  return null;
}

/// Stable colors for relationship roles across light/dark themes.
Color roleColor(NodeRole role, ColorScheme scheme) {
  return switch (role) {
    NodeRole.parent => const Color(0xFF2F6FED),
    NodeRole.focus => scheme.primary,
    NodeRole.child => const Color(0xFF0F8A5F),
    NodeRole.related => const Color(0xFFB05C1B),
  };
}

Color edgeColor(GraphEdge edge, ColorScheme scheme) {
  if (edge.isRelated) return roleColor(NodeRole.related, scheme).withValues(alpha: 0.55);
  return roleColor(NodeRole.parent, scheme).withValues(alpha: 0.45);
}
