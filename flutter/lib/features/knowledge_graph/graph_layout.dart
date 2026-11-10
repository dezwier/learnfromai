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
    required this.radius,
    this.isFlower = false,
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
  /// Unit hex circumradius used to draw this node (flower uses same unit).
  final double radius;
  /// Focus is the solid union of 7 unit hexes (no internal gaps).
  final bool isFlower;
  final String? description;

  Offset get center => Offset(x + width / 2, y + height / 2);

  bool contains(Offset point) {
    final local = point - center;
    if (!isFlower) return pointInFlatHex(local, radius);
    return pointInHexFlower(local, radius);
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

const graphFocusWidth = 168.0;
const graphFocusHeight = 96.0;
const graphCardWidth = 118.0;
const graphSideGap = 8.0;

/// Equal inset so unit hexes (and the flower outline) leave a thin strip.
const hexGapInset = 0.05;

/// Flat-top axial cells that make the 7-hex focus flower.
const flowerCells = <(int, int)>[
  (0, 0),
  (1, 0),
  (1, -1),
  (0, -1),
  (-1, 0),
  (-1, 1),
  (0, 1),
];

Path flatHexPath(double radius, {Offset center = Offset.zero}) {
  final path = Path();
  for (var i = 0; i < 6; i++) {
    final angle = i * math.pi / 3;
    final point = Offset(
      center.dx + radius * math.cos(angle),
      center.dy + radius * math.sin(angle),
    );
    if (i == 0) {
      path.moveTo(point.dx, point.dy);
    } else {
      path.lineTo(point.dx, point.dy);
    }
  }
  path.close();
  return path;
}

/// Solid union of center + 6 neighbors — one continuous focus region.
Path hexFlowerPath(double unitRadius, {Offset center = Offset.zero}) {
  Path? path;
  for (final cell in flowerCells) {
    final c = center + axialToPixel(cell.$1, cell.$2, unitRadius);
    final hex = flatHexPath(unitRadius, center: c);
    path = path == null ? hex : Path.combine(PathOperation.union, path, hex);
  }
  return path!;
}

bool pointInFlatHex(Offset local, double radius) {
  final ax = local.dx.abs();
  final ay = local.dy.abs();
  if (ax > radius || ay > radius * math.sqrt(3) / 2) return false;
  return radius * math.sqrt(3) - math.sqrt(3) * ax - ay >= -1e-6;
}

bool pointInHexFlower(Offset local, double unitRadius) {
  for (final cell in flowerCells) {
    final c = axialToPixel(cell.$1, cell.$2, unitRadius);
    if (pointInFlatHex(local - c, unitRadius)) return true;
  }
  return false;
}

Size flatHexBounds(double radius) => Size(radius * 2, radius * math.sqrt(3));

/// Bounding box of the 7-hex flower for unit circumradius [unitRadius].
Size hexFlowerBounds(double unitRadius) {
  return Size(unitRadius * 5, unitRadius * 3 * math.sqrt(3));
}

/// Tight honeycomb on a flat-top axial lattice.
/// Focus is one solid 7-hex flower; neighbors are unit hexes from ring 2.
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

  final queue = <(GraphNode, NodeRole)>[
    for (final node in parents) (node, NodeRole.parent),
    for (final node in children) (node, NodeRole.child),
    for (final node in siblings) (node, NodeRole.sibling),
    for (final node in related) (node, NodeRole.related),
  ];

  final cells = _ringCells(fromRing: 2, count: math.max(queue.length, 1));
  final used = <int>{};
  final assignments = <(GraphNode, _HexCell)>[];

  for (final item in queue) {
    var best = -1;
    var bestScore = -9999.0;
    for (var i = 0; i < cells.length; i++) {
      if (used.contains(i)) continue;
      final score = _cellScore(cells[i], item.$2);
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    if (best < 0) break;
    used.add(best);
    assignments.add((item.$1, cells[best]));
  }

  // Unit lattice size = 1. Focus flower bounds use the 7-cell footprint.
  final focusBounds = hexFlowerBounds(1.0);
  final centers = <(GraphNode, Offset, bool)>[
    (focusNode, Offset.zero, true),
    for (final a in assignments) (a.$1, axialToPixel(a.$2.q, a.$2.r, 1.0), false),
  ];

  var minX = -focusBounds.width / 2;
  var maxX = focusBounds.width / 2;
  var minY = -focusBounds.height / 2;
  var maxY = focusBounds.height / 2;
  for (final c in centers) {
    if (c.$3) continue;
    final b = flatHexBounds(1.0);
    minX = math.min(minX, c.$2.dx - b.width / 2);
    maxX = math.max(maxX, c.$2.dx + b.width / 2);
    minY = math.min(minY, c.$2.dy - b.height / 2);
    maxY = math.max(maxY, c.$2.dy + b.height / 2);
  }

  const pad = 8.0;
  final contentW = math.max(maxX - minX, 1.0);
  final contentH = math.max(maxY - minY, 1.0);
  final scale = math.min((width - 2 * pad) / contentW, (height - 2 * pad) / contentH);
  final ox = (width - contentW * scale) / 2 - minX * scale;
  final oy = (height - contentH * scale) / 2 - minY * scale;
  final unit = scale * (1 - hexGapInset);

  final placed = <PlacedNode>[];
  for (final c in centers) {
    final cx = c.$2.dx * scale + ox;
    final cy = c.$2.dy * scale + oy;
    if (c.$3) {
      placed.add(_flower(c.$1, cx: cx, cy: cy, unitRadius: unit));
    } else {
      placed.add(_hex(c.$1, cx: cx, cy: cy, radius: unit));
    }
  }

  return GraphLayout(nodes: placed, width: width, height: height);
}

class _HexCell {
  const _HexCell(this.q, this.r);

  final int q;
  final int r;

  int get s => -q - r;
  int get ring => (q.abs() + r.abs() + s.abs()) ~/ 2;
}

Offset axialToPixel(int q, int r, double size) {
  final x = size * (3 / 2) * q;
  final y = size * (math.sqrt(3) / 2 * q + math.sqrt(3) * r);
  return Offset(x, y);
}

List<_HexCell> _ringCells({required int fromRing, required int count}) {
  final out = <_HexCell>[];
  var ring = fromRing;
  while (out.length < count && ring <= fromRing + 8) {
    out.addAll(_cellsOnRing(ring));
    ring++;
  }
  return out;
}

List<_HexCell> _cellsOnRing(int ring) {
  if (ring <= 0) return const [_HexCell(0, 0)];
  const dirs = [
    (1, 0),
    (1, -1),
    (0, -1),
    (-1, 0),
    (-1, 1),
    (0, 1),
  ];
  var q = dirs[4].$1 * ring;
  var r = dirs[4].$2 * ring;
  final cells = <_HexCell>[];
  for (var i = 0; i < 6; i++) {
    final d = dirs[i];
    for (var j = 0; j < ring; j++) {
      cells.add(_HexCell(q, r));
      q += d.$1;
      r += d.$2;
    }
  }
  return cells;
}

double _cellScore(_HexCell cell, NodeRole role) {
  final c = axialToPixel(cell.q, cell.r, 1.0);
  final angle = math.atan2(c.dy, c.dx);
  final north = _angleDist(angle, -math.pi / 2);
  final south = _angleDist(angle, math.pi / 2);
  final east = _angleDist(angle, 0);
  final west = _angleDist(angle, math.pi);
  final ringPenalty = (cell.ring - 2) * 0.45;

  return switch (role) {
    NodeRole.parent => 4.0 - north - ringPenalty,
    NodeRole.child => 4.0 - south - ringPenalty,
    NodeRole.sibling => 4.0 - math.min(east, west) - ringPenalty,
    NodeRole.related => 2.0 - ringPenalty * 0.5,
    NodeRole.focus => 0,
  };
}

double _angleDist(double a, double b) {
  var d = (a - b).abs() % (2 * math.pi);
  if (d > math.pi) d = 2 * math.pi - d;
  return d;
}

PlacedNode _hex(GraphNode node, {required double cx, required double cy, required double radius}) {
  final bounds = flatHexBounds(radius);
  return PlacedNode(
    id: node.id,
    title: node.title,
    depth: node.depth,
    distance: node.distance,
    kind: node.kind,
    role: node.role,
    description: node.description,
    radius: radius,
    x: cx - bounds.width / 2,
    y: cy - bounds.height / 2,
    width: bounds.width,
    height: bounds.height,
  );
}

PlacedNode _flower(GraphNode node, {required double cx, required double cy, required double unitRadius}) {
  final bounds = hexFlowerBounds(unitRadius);
  return PlacedNode(
    id: node.id,
    title: node.title,
    depth: node.depth,
    distance: node.distance,
    kind: node.kind,
    role: node.role,
    description: node.description,
    radius: unitRadius,
    isFlower: true,
    x: cx - bounds.width / 2,
    y: cy - bounds.height / 2,
    width: bounds.width,
    height: bounds.height,
  );
}

String? hitTestNode(GraphLayout layout, Offset point) {
  for (final node in layout.nodes.reversed) {
    if (node.contains(point)) return node.id;
  }
  return null;
}

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

class HexagonBorder extends ShapeBorder {
  const HexagonBorder();

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => getOuterPath(rect);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    final radius = math.min(rect.width / 2, rect.height / math.sqrt(3));
    return flatHexPath(radius, center: rect.center);
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;
}

/// Outline of the solid 7-hex focus flower.
class HexFlowerBorder extends ShapeBorder {
  const HexFlowerBorder();

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => getOuterPath(rect);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    final unit = math.min(rect.width / 5, rect.height / (3 * math.sqrt(3)));
    return hexFlowerPath(unit, center: rect.center);
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;
}
