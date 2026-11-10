import 'dart:math' as math;

import 'package:flutter/material.dart';

class GraphNode {
  const GraphNode({required this.id, required this.title, required this.depth, this.distance = 0});

  final int id;
  final String title;
  final int depth;
  final int distance;
}

class GraphEdge {
  const GraphEdge({required this.source, required this.target});

  final int source;
  final int target;
}

class PlacedHex {
  const PlacedHex({
    required this.id,
    required this.title,
    required this.depth,
    required this.distance,
    required this.x,
    required this.y,
    required this.radius,
    required this.showLabel,
  });

  final int id;
  final String title;
  final int depth;
  final int distance;
  final double x;
  final double y;
  final double radius;
  final bool showLabel;

  bool contains(Offset point) {
    final dx = point.dx - x;
    final dy = point.dy - y;
    return dx * dx + dy * dy <= radius * radius;
  }
}

class HexLayout {
  const HexLayout({required this.cells, required this.width, required this.height});

  final List<PlacedHex> cells;
  final double width;
  final double height;
}

class ZoomWindow {
  const ZoomWindow({required this.climb, required this.expand});

  final int climb;
  final int expand;
}

const hexLabelFontSize = 13.0;
const hexRootRadius = 180.0;

/// Default: the focus hex, split into its children.
/// Zoom out: climb to the parent (still only the explored path).
/// Zoom in: same children, larger.
ZoomWindow zoomWindowFor(double scale) {
  if (scale < 0.7) return const ZoomWindow(climb: 1, expand: 0);
  if (scale < 1.1) return const ZoomWindow(climb: 0, expand: 1);
  return const ZoomWindow(climb: 0, expand: 1);
}

List<(int, int)> flowerAxial(int count, {bool includeCenter = false}) {
  if (count <= 0) return const [];
  const dirs = [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)];
  final result = <(int, int)>[];
  if (includeCenter || count == 1) {
    result.add((0, 0));
    if (result.length >= count) return result;
  }
  var ring = 1;
  while (result.length < count) {
    var q = dirs[4].$1 * ring;
    var r = dirs[4].$2 * ring;
    for (var side = 0; side < 6; side++) {
      for (var step = 0; step < ring; step++) {
        result.add((q, r));
        if (result.length >= count) return result;
        q += dirs[side].$1;
        r += dirs[side].$2;
      }
    }
    ring += 1;
  }
  return result;
}

int ringsFor(int count) {
  if (count <= 1) return 0;
  var ring = 1;
  var capacity = 6;
  while (capacity < count) {
    ring += 1;
    capacity += 6 * ring;
  }
  return ring;
}

Offset axialToPixel(int q, int r, double hexRadius) {
  final width = math.sqrt(3) * hexRadius;
  final height = 1.5 * hexRadius;
  return Offset(width * (q + r / 2), height * r);
}

double estimateLabelWidth(String title, double fontSize) => title.length * fontSize * 0.62;

class _RawHex {
  const _RawHex(this.node, this.center, this.radius);

  final GraphNode node;
  final Offset center;
  final double radius;
}

HexLayout layoutHexMap(
  List<GraphNode> nodes,
  List<GraphEdge> edges, {
  required int focusId,
  ZoomWindow? window,
  double rootRadius = hexRootRadius,
  double scale = 1,
  double fontSize = hexLabelFontSize,
}) {
  if (nodes.isEmpty) {
    return const HexLayout(cells: [], width: 0, height: 0);
  }
  final byId = {for (final node in nodes) node.id: node};
  final children = <int, List<GraphNode>>{};
  final parents = <int, List<GraphNode>>{};
  for (final edge in edges) {
    final parent = byId[edge.source];
    final child = byId[edge.target];
    if (parent == null || child == null) continue;
    children.putIfAbsent(parent.id, () => []).add(child);
    parents.putIfAbsent(child.id, () => []).add(parent);
  }
  for (final list in children.values) {
    list.sort((a, b) => a.id.compareTo(b.id));
  }
  for (final list in parents.values) {
    list.sort((a, b) => a.depth.compareTo(b.depth));
  }

  final zoom = window ?? zoomWindowFor(scale);
  final focus = byId[focusId] ?? nodes.first;
  var root = focus;
  for (var step = 0; step < zoom.climb; step++) {
    final above = parents[root.id];
    if (above == null || above.isEmpty) break;
    root = above.first;
  }

  final placed = <_RawHex>[];
  void place(GraphNode node, Offset center, double radius, int remaining) {
    final kids = [...(children[node.id] ?? const <GraphNode>[])];
    if (kids.isEmpty || remaining <= 0) {
      placed.add(_RawHex(node, center, radius));
      return;
    }
    kids.sort((a, b) {
      if (a.id == focusId) return -1;
      if (b.id == focusId) return 1;
      return a.id.compareTo(b.id);
    });
    final coords = flowerAxial(kids.length, includeCenter: kids.first.id == focusId);
    final rings = math.max(1, ringsFor(kids.length));
    final childRadius = radius / (2 * rings + 1);
    for (var index = 0; index < kids.length; index++) {
      final pixel = axialToPixel(coords[index].$1, coords[index].$2, childRadius);
      place(kids[index], center + pixel, childRadius, remaining - 1);
    }
  }

  place(root, Offset.zero, rootRadius, zoom.expand);

  if (placed.isEmpty) {
    return const HexLayout(cells: [], width: 0, height: 0);
  }
  var minX = placed.first.center.dx - placed.first.radius;
  var maxX = placed.first.center.dx + placed.first.radius;
  var minY = placed.first.center.dy - placed.first.radius;
  var maxY = placed.first.center.dy + placed.first.radius;
  for (final cell in placed) {
    minX = math.min(minX, cell.center.dx - cell.radius);
    maxX = math.max(maxX, cell.center.dx + cell.radius);
    minY = math.min(minY, cell.center.dy - cell.radius);
    maxY = math.max(maxY, cell.center.dy + cell.radius);
  }
  const margin = 28.0;
  final shift = Offset(margin - minX, margin - minY);
  final ranked = [...placed]
    ..sort((a, b) {
      final byDistance = a.node.distance.compareTo(b.node.distance);
      if (byDistance != 0) return byDistance;
      return b.radius.compareTo(a.radius);
    });
  final occupied = <Rect>[];
  final labeled = <int>{};
  for (final cell in ranked) {
    final width = estimateLabelWidth(cell.node.title, fontSize);
    final hexWidth = 2 * cell.radius * scale;
    if (hexWidth < width + 12) continue;
    final center = cell.center + shift;
    final rect = Rect.fromCenter(center: center, width: width, height: fontSize + 6);
    if (occupied.any((other) => other.overlaps(rect))) continue;
    occupied.add(rect);
    labeled.add(cell.node.id);
  }
  final cells = [
    for (final cell in placed)
      PlacedHex(
        id: cell.node.id,
        title: cell.node.title,
        depth: cell.node.depth,
        distance: cell.node.distance,
        x: cell.center.dx + shift.dx,
        y: cell.center.dy + shift.dy,
        radius: cell.radius,
        showLabel: labeled.contains(cell.node.id),
      ),
  ];
  return HexLayout(
    cells: cells,
    width: maxX - minX + margin * 2,
    height: maxY - minY + margin * 2,
  );
}

int? hitTestHex(HexLayout layout, Offset point) {
  PlacedHex? best;
  for (final cell in layout.cells) {
    if (!cell.contains(point)) continue;
    if (best == null || cell.radius < best.radius) best = cell;
  }
  return best?.id;
}
