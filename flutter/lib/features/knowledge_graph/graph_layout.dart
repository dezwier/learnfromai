import 'dart:math' as math;

import 'package:flutter/material.dart';

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
}

class GraphEdge {
  const GraphEdge({required this.source, required this.target, this.type = 'subclass_of'});

  final int source;
  final int target;
  final String type;
}

class PlacedNode {
  const PlacedNode({
    required this.id,
    required this.title,
    required this.depth,
    required this.distance,
    required this.kind,
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
  final double x;
  final double y;
  final double width;
  final double height;

  bool contains(Offset point) {
    return point.dx >= x && point.dx <= x + width && point.dy >= y && point.dy <= y + height;
  }
}

class HierarchyLayout {
  const HierarchyLayout({
    required this.nodes,
    required this.edges,
    required this.related,
    required this.width,
    required this.height,
  });

  final List<PlacedNode> nodes;
  final List<GraphEdge> edges;
  final List<GraphNode> related;
  final double width;
  final double height;
}

const hierarchyCardWidth = 160.0;
const hierarchyCardHeight = 56.0;
const hierarchyGapX = 24.0;
const hierarchyGapY = 72.0;
const hierarchyPadding = 48.0;

HierarchyLayout layoutHierarchy(
  List<GraphNode> nodes,
  List<GraphEdge> edges, {
  required int focusId,
}) {
  final byId = {for (final node in nodes) node.id: node};
  final related = [
    for (final node in nodes)
      if (node.kind == 'related' || (node.id != focusId && node.depth == 0 && node.kind != 'focus'))
        node,
  ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

  final relatedIds = {for (final node in related) node.id};
  final hierarchyNodes = [
    for (final node in nodes)
      if (!relatedIds.contains(node.id) || node.id == focusId) node,
  ];

  final parents = [
    for (final node in hierarchyNodes)
      if (node.depth < 0) node,
  ]..sort((a, b) => a.depth.compareTo(b.depth));
  GraphNode? focus = byId[focusId];
  if (focus == null) {
    for (final node in hierarchyNodes) {
      if (node.depth == 0) {
        focus = node;
        break;
      }
    }
  }
  focus ??= hierarchyNodes.isEmpty ? null : hierarchyNodes.first;
  final children = [
    for (final node in hierarchyNodes)
      if (node.depth > 0) node,
  ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

  final rows = <List<GraphNode>>[];
  if (parents.isNotEmpty) rows.add(parents);
  if (focus != null) rows.add([focus]);
  if (children.isNotEmpty) rows.add(children);

  final placed = <PlacedNode>[];
  var maxWidth = hierarchyPadding * 2;
  var y = hierarchyPadding;
  for (final row in rows) {
    final rowWidth = row.length * hierarchyCardWidth + math.max(0, row.length - 1) * hierarchyGapX;
    maxWidth = math.max(maxWidth, rowWidth + hierarchyPadding * 2);
    var x = hierarchyPadding;
    // Center the row later after we know canvas width.
    for (final node in row) {
      placed.add(
        PlacedNode(
          id: node.id,
          title: node.title,
          depth: node.depth,
          distance: node.distance,
          kind: node.kind,
          x: x,
          y: y,
          width: hierarchyCardWidth,
          height: hierarchyCardHeight,
        ),
      );
      x += hierarchyCardWidth + hierarchyGapX;
    }
    y += hierarchyCardHeight + hierarchyGapY;
  }

  final width = math.max(maxWidth, 320.0);
  final centered = <PlacedNode>[];
  // Re-center each depth band.
  final byDepth = <int, List<PlacedNode>>{};
  for (final node in placed) {
    byDepth.putIfAbsent(node.depth, () => []).add(node);
  }
  for (final entry in byDepth.entries) {
    final band = entry.value;
    final bandWidth = band.length * hierarchyCardWidth + math.max(0, band.length - 1) * hierarchyGapX;
    var x = (width - bandWidth) / 2;
    for (final node in band) {
      centered.add(
        PlacedNode(
          id: node.id,
          title: node.title,
          depth: node.depth,
          distance: node.distance,
          kind: node.kind,
          x: x,
          y: node.y,
          width: node.width,
          height: node.height,
        ),
      );
      x += hierarchyCardWidth + hierarchyGapX;
    }
  }

  final visibleEdges = [
    for (final edge in edges)
      if (edge.type != 'related_to' &&
          centered.any((node) => node.id == edge.source) &&
          centered.any((node) => node.id == edge.target))
        edge,
  ];

  final height = y - hierarchyGapY + hierarchyPadding;
  return HierarchyLayout(
    nodes: centered,
    edges: visibleEdges,
    related: related,
    width: width,
    height: math.max(height, 240.0),
  );
}

int? hitTestNode(HierarchyLayout layout, Offset point) {
  for (final node in layout.nodes.reversed) {
    if (node.contains(point)) return node.id;
  }
  return null;
}
