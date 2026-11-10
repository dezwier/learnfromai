import 'dart:math' as math;

import 'package:flutter/material.dart';

enum NodeRole { parent, focus, sibling, child, related }

class GraphNode {
  const GraphNode({
    required this.id,
    required this.title,
    required this.depth,
    this.distance = 0,
    this.kind = 'focus',
    this.description,
  });

  final String id;
  final String title;
  final int depth;
  final int distance;
  final String kind;
  final String? description;

  NodeRole get role {
    switch (kind) {
      case 'parent':
        return NodeRole.parent;
      case 'sibling':
        return NodeRole.sibling;
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
  const GraphEdge({required this.source, required this.target, this.type = 'child'});

  final String source;
  final String target;
  final String type;
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
    this.description,
  });

  final String id;
  final String title;
  final int depth;
  final int distance;
  final String kind;
  final NodeRole role;
  final double x;
  final double y;
  final double width;
  final double height;
  final String? description;

  Offset get center => Offset(x + width / 2, y + height / 2);

  bool contains(Offset point) {
    return point.dx >= x && point.dx <= x + width && point.dy >= y && point.dy <= y + height;
  }
}

class GraphLayout {
  const GraphLayout({
    required this.nodes,
    required this.width,
    required this.height,
  });

  final List<PlacedNode> nodes;
  final double width;
  final double height;
}

const mosaicGap = 3.0;
const graphFocusWidth = 168.0; // kept for older test imports
const graphFocusHeight = 96.0;
const graphCardWidth = 118.0;
const graphSideGap = 8.0;

/// Tile pastel boxes into the viewport. Focus center, parents above, children below,
/// siblings on the sides, related filling the remaining perimeter.
GraphLayout layoutGraph(
  List<GraphNode> nodes,
  List<GraphEdge> _, {
  required String focusId,
  Size viewport = const Size(390, 720),
}) {
  final width = math.max(viewport.width, 280.0);
  final height = math.max(viewport.height, 360.0);
  if (nodes.isEmpty) {
    return GraphLayout(nodes: const [], width: width, height: height);
  }

  final byId = {for (final node in nodes) node.id: node};
  GraphNode? focus = byId[focusId];
  if (focus == null) {
    for (final node in nodes) {
      if (node.role == NodeRole.focus) {
        focus = node;
        break;
      }
    }
  }
  focus ??= nodes.first;
  final focusNode = focus;

  final parents = [
    for (final node in nodes)
      if (node.role == NodeRole.parent) node,
  ]..sort((a, b) => a.depth.compareTo(b.depth));
  final children = [
    for (final node in nodes)
      if (node.role == NodeRole.child) node,
  ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  final siblings = [
    for (final node in nodes)
      if (node.role == NodeRole.sibling) node,
  ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  final related = [
    for (final node in nodes)
      if (node.role == NodeRole.related && node.id != focusNode.id) node,
  ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

  final hasTop = parents.isNotEmpty || related.isNotEmpty;
  final hasBottom = children.isNotEmpty || related.length > 2;
  final hasSides = siblings.isNotEmpty || related.isNotEmpty;

  final topH = hasTop ? height * (parents.isEmpty ? 0.16 : 0.20) : 0.0;
  final bottomH = hasBottom ? height * (children.isEmpty ? 0.16 : 0.22) : 0.0;
  final midH = height - topH - bottomH - (hasTop ? mosaicGap : 0) - (hasBottom ? mosaicGap : 0);
  final sideW = hasSides ? width * 0.27 : 0.0;
  final centerW = width - (hasSides ? sideW * 2 + mosaicGap * 2 : 0);

  final midY = hasTop ? topH + mosaicGap : 0.0;
  final bottomY = midY + midH + (hasBottom ? mosaicGap : 0);
  final centerX = hasSides ? sideW + mosaicGap : 0.0;

  final placed = <PlacedNode>[];
  final relatedPool = List<GraphNode>.of(related);

  // Top band: parents across the middle; related in leftover top cells.
  if (hasTop) {
    if (parents.isNotEmpty) {
      placed.addAll(_splitRow(parents, x: 0, y: 0, width: width, height: topH));
    } else {
      final take = math.min(relatedPool.length, 3);
      placed.addAll(_splitRow(relatedPool.sublist(0, take), x: 0, y: 0, width: width, height: topH));
      relatedPool.removeRange(0, take);
    }
  }

  // Focus center.
  placed.add(
    _box(focusNode, x: centerX, y: midY, width: centerW, height: midH),
  );

  // Side columns: siblings first, then related leftovers.
  final leftSiblings = [for (var i = 0; i < siblings.length; i += 2) siblings[i]];
  final rightSiblings = [for (var i = 1; i < siblings.length; i += 2) siblings[i]];

  if (hasSides) {
    final leftItems = <GraphNode>[...leftSiblings];
    final rightItems = <GraphNode>[...rightSiblings];
    while (relatedPool.isNotEmpty && leftItems.length <= rightItems.length) {
      leftItems.add(relatedPool.removeAt(0));
      if (relatedPool.isEmpty) break;
      rightItems.add(relatedPool.removeAt(0));
    }
    while (relatedPool.isNotEmpty) {
      (leftItems.length <= rightItems.length ? leftItems : rightItems).add(relatedPool.removeAt(0));
    }
    if (leftItems.isNotEmpty) {
      placed.addAll(_splitColumn(leftItems, x: 0, y: midY, width: sideW, height: midH));
    }
    if (rightItems.isNotEmpty) {
      placed.addAll(
        _splitColumn(rightItems, x: centerX + centerW + mosaicGap, y: midY, width: sideW, height: midH),
      );
    }
  }

  // Bottom band: children, then any remaining related.
  if (hasBottom) {
    final bottomItems = <GraphNode>[...children, ...relatedPool];
    if (bottomItems.isNotEmpty) {
      placed.addAll(_splitRow(bottomItems, x: 0, y: bottomY, width: width, height: bottomH));
    }
  } else if (relatedPool.isNotEmpty && midH > 0) {
    // Rare: only related left and no bottom band — fold into sides already handled.
  }

  return GraphLayout(nodes: placed, width: width, height: height);
}

List<PlacedNode> _splitRow(List<GraphNode> items, {required double x, required double y, required double width, required double height}) {
  if (items.isEmpty || width <= 0 || height <= 0) return const [];
  final gaps = mosaicGap * math.max(0, items.length - 1);
  final cell = (width - gaps) / items.length;
  return [
    for (var i = 0; i < items.length; i++)
      _box(items[i], x: x + i * (cell + mosaicGap), y: y, width: cell, height: height),
  ];
}

List<PlacedNode> _splitColumn(
  List<GraphNode> items, {
  required double x,
  required double y,
  required double width,
  required double height,
}) {
  if (items.isEmpty || width <= 0 || height <= 0) return const [];
  final gaps = mosaicGap * math.max(0, items.length - 1);
  final cell = (height - gaps) / items.length;
  return [
    for (var i = 0; i < items.length; i++)
      _box(items[i], x: x, y: y + i * (cell + mosaicGap), width: width, height: cell),
  ];
}

PlacedNode _box(GraphNode node, {required double x, required double y, required double width, required double height}) {
  return PlacedNode(
    id: node.id,
    title: node.title,
    depth: node.depth,
    distance: node.distance,
    kind: node.kind,
    role: node.role,
    description: node.description,
    x: x,
    y: y,
    width: width,
    height: height,
  );
}

String? hitTestNode(GraphLayout layout, Offset point) {
  for (final node in layout.nodes.reversed) {
    if (node.contains(point)) return node.id;
  }
  return null;
}

/// Soft opaque pastel fills for node roles.
Color roleFill(NodeRole role, ColorScheme scheme) {
  final dark = scheme.brightness == Brightness.dark;
  return switch (role) {
    NodeRole.parent => dark ? const Color(0xFF2A3F5C) : const Color(0xFFD7E6F8),
    NodeRole.focus => dark ? const Color(0xFF3D4A5C) : const Color(0xFFE8EEF5),
    NodeRole.sibling => dark ? const Color(0xFF3A2F55) : const Color(0xFFE8DDF8),
    NodeRole.child => dark ? const Color(0xFF243F36) : const Color(0xFFD5EEE3),
    NodeRole.related => dark ? const Color(0xFF4A3A2A) : const Color(0xFFF3E4D4),
  };
}

Color roleColor(NodeRole role, ColorScheme scheme) => roleFill(role, scheme);
