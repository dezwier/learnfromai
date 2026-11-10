import 'dart:math' as math;

import 'package:flutter/material.dart';

enum NodeRole { parent, focus, sibling, child, related, extended }

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
      case 'extended':
        return NodeRole.extended;
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
  /// Lattice unit circumradius (centers sit on the full grid; drawing insets).
  final double radius;
  /// Focus is the solid union of 7 unit hexes (no internal gaps).
  final bool isFlower;
  final String? description;

  Offset get center => Offset(x + width / 2, y + height / 2);

  double get drawnRadius => radius * (1 - hexGapInset);

  bool contains(Offset point) {
    final local = point - center;
    if (!isFlower) return pointInFlatHex(local, drawnRadius);
    return pointInHexFlower(local, latticeSize: radius);
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
const hexGapInset = 0.08;

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

/// Soft corner radius as a fraction of hex circumradius.
const hexCornerFraction = 0.16;

/// Rounded polygon via quadratic corners at each vertex.
Path roundedPolygonPath(List<Offset> verts, {required double cornerRadius}) {
  if (verts.length < 3) return Path();
  if (cornerRadius <= 0) {
    final path = Path()..moveTo(verts.first.dx, verts.first.dy);
    for (var i = 1; i < verts.length; i++) {
      path.lineTo(verts[i].dx, verts[i].dy);
    }
    path.close();
    return path;
  }

  final path = Path();
  final n = verts.length;
  for (var i = 0; i < n; i++) {
    final prev = verts[(i - 1 + n) % n];
    final cur = verts[i];
    final next = verts[(i + 1) % n];
    final toPrev = prev - cur;
    final toNext = next - cur;
    final dPrev = toPrev.distance;
    final dNext = toNext.distance;
    if (dPrev < 1e-9 || dNext < 1e-9) continue;
    final r = math.min(cornerRadius, math.min(dPrev, dNext) * 0.4);
    final p1 = cur + toPrev * (r / dPrev);
    final p2 = cur + toNext * (r / dNext);
    if (i == 0) {
      path.moveTo(p1.dx, p1.dy);
    } else {
      path.lineTo(p1.dx, p1.dy);
    }
    path.quadraticBezierTo(cur.dx, cur.dy, p2.dx, p2.dy);
  }
  path.close();
  return path;
}

Path flatHexPath(double radius, {Offset center = Offset.zero}) {
  final verts = [
    for (var i = 0; i < 6; i++)
      Offset(
        center.dx + radius * math.cos(i * math.pi / 3),
        center.dy + radius * math.sin(i * math.pi / 3),
      ),
  ];
  return roundedPolygonPath(verts, cornerRadius: radius * hexCornerFraction);
}

/// Same distance a unit-hex flat retreats when radius *= (1 - hexGapInset).
double hexFlatInset(double latticeSize) =>
    (math.sqrt(3) / 2) * latticeSize * hexGapInset;

Offset _snap(Offset p) => Offset(
      (p.dx * 10000).round() / 10000,
      (p.dy * 10000).round() / 10000,
    );

String _pointKey(Offset p) => '${p.dx},${p.dy}';

/// Outer boundary of the 7-hex flower (18 verts), origin-centered.
List<Offset> hexFlowerOutline(double R) {
  final counts = <String, int>{};
  final ends = <String, (Offset, Offset)>{};

  String edgeKey(Offset a, Offset b) {
    final ka = _pointKey(a);
    final kb = _pointKey(b);
    return ka.compareTo(kb) <= 0 ? '$ka|$kb' : '$kb|$ka';
  }

  for (final cell in flowerCells) {
    final c = axialToPixel(cell.$1, cell.$2, R);
    final verts = [
      for (var i = 0; i < 6; i++)
        _snap(Offset(
          c.dx + R * math.cos(i * math.pi / 3),
          c.dy + R * math.sin(i * math.pi / 3),
        )),
    ];
    for (var i = 0; i < 6; i++) {
      final a = verts[i];
      final b = verts[(i + 1) % 6];
      final k = edgeKey(a, b);
      counts[k] = (counts[k] ?? 0) + 1;
      ends[k] = (a, b);
    }
  }

  final outlineEdges = [
    for (final e in counts.entries)
      if (e.value == 1) ends[e.key]!,
  ];
  if (outlineEdges.isEmpty) {
    return const [Offset(1, 0), Offset(0.5, 0.866), Offset(-0.5, 0.866), Offset(-1, 0), Offset(-0.5, -0.866), Offset(0.5, -0.866)]
        .map((o) => o * R)
        .toList();
  }

  final adj = <String, List<Offset>>{};
  for (final e in outlineEdges) {
    adj.putIfAbsent(_pointKey(e.$1), () => []).add(e.$2);
    adj.putIfAbsent(_pointKey(e.$2), () => []).add(e.$1);
  }

  final start = outlineEdges.first.$1;
  final loop = <Offset>[start];
  var prevKey = '';
  var cur = start;
  while (loop.length <= outlineEdges.length) {
    final options = adj[_pointKey(cur)]!;
    final next = options.firstWhere(
      (p) => _pointKey(p) != prevKey,
      orElse: () => options.first,
    );
    if (_pointKey(next) == _pointKey(start)) break;
    prevKey = _pointKey(cur);
    cur = next;
    loop.add(cur);
  }
  return loop;
}

double _polygonWidth(List<Offset> verts) {
  var minX = double.infinity;
  var maxX = -double.infinity;
  for (final v in verts) {
    minX = math.min(minX, v.dx);
    maxX = math.max(maxX, v.dx);
  }
  return maxX - minX;
}

List<Offset> _offsetPolygon(List<Offset> pts, double dist, {required bool leftNormal}) {
  Offset normal(Offset from, Offset to) {
    final dx = to.dx - from.dx;
    final dy = to.dy - from.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1e-12) return Offset.zero;
    final n = Offset(-dy / len, dx / len); // left of edge
    return leftNormal ? n : -n;
  }

  Offset intersect(Offset p1, Offset d1, Offset p2, Offset d2) {
    final cross = d1.dx * d2.dy - d1.dy * d2.dx;
    if (cross.abs() < 1e-12) return Offset(p1.dx + d1.dx, p1.dy + d1.dy);
    final t = ((p2.dx - p1.dx) * d2.dy - (p2.dy - p1.dy) * d2.dx) / cross;
    return Offset(p1.dx + d1.dx * t, p1.dy + d1.dy * t);
  }

  final n = pts.length;
  final out = <Offset>[];
  for (var i = 0; i < n; i++) {
    final prev = pts[(i - 1 + n) % n];
    final cur = pts[i];
    final next = pts[(i + 1) % n];
    final n1 = normal(prev, cur);
    final n2 = normal(cur, next);
    final o1 = Offset(prev.dx + n1.dx * dist, prev.dy + n1.dy * dist);
    final o2 = Offset(cur.dx + n2.dx * dist, cur.dy + n2.dy * dist);
    out.add(intersect(o1, cur - prev, o2, next - cur));
  }
  return out;
}

/// Constant-distance inward inset for the flower outline.
List<Offset> _insetPolygon(List<Offset> verts, double dist) {
  if (verts.length < 3 || dist <= 0) return verts;
  final pts = List<Offset>.of(verts);
  final candidate = _offsetPolygon(pts, dist, leftNormal: true);
  // Pick the offset that shrinks the shape (inward).
  if (_polygonWidth(candidate) < _polygonWidth(pts)) return candidate;
  return _offsetPolygon(pts, dist, leftNormal: false);
}

Path _pathFromVerts(List<Offset> verts, Offset center, {required double cornerRadius}) {
  final shifted = [for (final v in verts) v + center];
  return roundedPolygonPath(shifted, cornerRadius: cornerRadius)..fillType = PathFillType.nonZero;
}

/// Solid 7-cell focus: full lattice outline, parallel-inset by the unit-hex flat
/// inset so every side has the same strip as neighboring hexes.
Path hexFlowerPath({
  required double latticeSize,
  Offset center = Offset.zero,
}) {
  final outline = hexFlowerOutline(latticeSize);
  final inset = _insetPolygon(outline, hexFlatInset(latticeSize));
  final path = _pathFromVerts(
    inset,
    center,
    cornerRadius: latticeSize * hexCornerFraction,
  );
  final ok = path.contains(center) && _polygonWidth(inset) < _polygonWidth(outline);
  if (!ok) {
    Path? solid;
    for (final cell in flowerCells) {
      final c = center + axialToPixel(cell.$1, cell.$2, latticeSize);
      final hex = flatHexPath(latticeSize * 1.02, center: c);
      solid = solid == null ? hex : Path.combine(PathOperation.union, solid, hex);
    }
    return solid!..fillType = PathFillType.nonZero;
  }
  return path;
}

bool pointInFlatHex(Offset local, double radius) {
  final ax = local.dx.abs();
  final ay = local.dy.abs();
  if (ax > radius || ay > radius * math.sqrt(3) / 2) return false;
  return radius * math.sqrt(3) - math.sqrt(3) * ax - ay >= -1e-6;
}

bool pointInHexFlower(Offset local, {required double latticeSize}) {
  return hexFlowerPath(latticeSize: latticeSize).contains(local);
}

Size flatHexBounds(double radius) => Size(radius * 2, radius * math.sqrt(3));

/// Bounding box of the 7-hex flower for unit circumradius [unitRadius].
Size hexFlowerBounds(double unitRadius) {
  return Size(unitRadius * 5, unitRadius * 3 * math.sqrt(3));
}

/// Tight honeycomb on a flat-top axial lattice.
/// Focus is one solid 7-hex flower; direct neighbors on ring 2+;
/// neighbors-of-neighbors sit next to the direct neighbor they hang off.
GraphLayout layoutGraph(
  List<GraphNode> nodes,
  List<GraphEdge> edges, {
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
  final extended = [
    for (final node in nodes)
      if (node.role == NodeRole.extended) node,
  ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

  final directs = <(GraphNode, NodeRole)>[
    for (final node in parents) (node, NodeRole.parent),
    for (final node in children) (node, NodeRole.child),
    for (final node in siblings) (node, NodeRole.sibling),
    for (final node in related) (node, NodeRole.related),
  ];
  final directIds = {for (final item in directs) item.$1.id};
  // extended id → preferred direct neighbor it hangs off.
  final viaDirect = <String, String>{};
  for (final edge in edges) {
    if (directIds.contains(edge.source) &&
        byId[edge.target]?.role == NodeRole.extended) {
      viaDirect.putIfAbsent(edge.target, () => edge.source);
    } else if (directIds.contains(edge.target) &&
        byId[edge.source]?.role == NodeRole.extended) {
      viaDirect.putIfAbsent(edge.source, () => edge.target);
    }
  }

  final slotBudget = _viewportSlotBudget(width, height, minDirect: directs.length);
  final fillers = extended.take(math.max(0, slotBudget - directs.length)).toList();

  // Include at least one outer ring beyond the directs so extended can sit
  // beside their anchors instead of only competing for leftover ring-2 cells.
  final cellPool = math.max(
    directs.length + fillers.length + 18,
    fillers.isEmpty ? directs.length : 30,
  );
  final cells = _ringCells(fromRing: 2, count: math.max(cellPool, 1));
  final used = <int>{};
  final assignments = <(GraphNode, _HexCell)>[];
  final cellByNodeId = <String, _HexCell>{};

  // 1) Place direct neighbors by role compass.
  for (final item in directs) {
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
    cellByNodeId[item.$1.id] = cells[best];
  }

  // 2) Place extended nodes next to their via-direct neighbor.
  final directCells = {
    for (final id in directIds)
      if (cellByNodeId.containsKey(id)) id: cellByNodeId[id]!,
  };
  for (final node in fillers) {
    final anchorId = viaDirect[node.id];
    final anchor = anchorId == null ? null : cellByNodeId[anchorId];
    var best = -1;
    var bestScore = -9999.0;
    for (var i = 0; i < cells.length; i++) {
      if (used.contains(i)) continue;
      final score = anchor == null
          ? _cellScore(cells[i], NodeRole.extended)
          : _nearAnchorScore(cells[i], anchor, directCells);
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    if (best < 0) break;
    used.add(best);
    assignments.add((node, cells[best]));
    cellByNodeId[node.id] = cells[best];
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

  final placed = <PlacedNode>[];
  for (final c in centers) {
    final cx = c.$2.dx * scale + ox;
    final cy = c.$2.dy * scale + oy;
    if (c.$3) {
      placed.add(_flower(c.$1, cx: cx, cy: cy, latticeSize: scale));
    } else {
      placed.add(_hex(c.$1, cx: cx, cy: cy, radius: scale));
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
  // Keep directs on ring 2 whenever a free cell remains there.
  final ringPenalty = (cell.ring - 2) * 1.8;

  return switch (role) {
    NodeRole.parent => 4.0 - north - ringPenalty,
    NodeRole.child => 4.0 - south - ringPenalty,
    NodeRole.sibling => 4.0 - math.min(east, west) - ringPenalty,
    NodeRole.related => 2.0 - ringPenalty * 0.5,
    NodeRole.extended => 1.0 - ringPenalty * 0.35,
    NodeRole.focus => 0,
  };
}

int _cubeDist(_HexCell a, _HexCell b) {
  final dq = a.q - b.q;
  final dr = a.r - b.r;
  final ds = a.s - b.s;
  return (dq.abs() + dr.abs() + ds.abs()) ~/ 2;
}

/// Prefer hexes adjacent to [anchor], outward, and uniquely closer to that via.
double _nearAnchorScore(
  _HexCell cell,
  _HexCell anchor,
  Map<String, _HexCell> directCells,
) {
  final dist = _cubeDist(cell, anchor);
  final outwardBoost = cell.ring >= anchor.ring ? 1.2 : -1.0;
  var score = 12.0 - dist * 3.0 + outwardBoost - (cell.ring - 2) * 0.15;
  for (final other in directCells.values) {
    if (other.q == anchor.q && other.r == anchor.r) continue;
    final dOther = _cubeDist(cell, other);
    if (dOther < dist) {
      score -= 5.0;
    } else if (dOther == dist) {
      score -= 2.0;
    }
  }
  return score;
}

/// How many surround hexes can stay readable in the viewport.
int _viewportSlotBudget(double width, double height, {required int minDirect}) {
  const minUnit = 26.0;
  const pad = 8.0;
  var ring = 2;
  var total = 0;
  while (ring <= 5) {
    final halfExtent = 2.5 + ring * math.sqrt(3);
    final unit = math.min((width - 2 * pad) / (2 * halfExtent), (height - 2 * pad) / (2 * halfExtent));
    if (unit < minUnit && total >= minDirect) break;
    total += ring * 6;
    if (unit < minUnit) break;
    ring++;
  }
  return math.max(total, minDirect);
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

PlacedNode _flower(GraphNode node, {required double cx, required double cy, required double latticeSize}) {
  final bounds = hexFlowerBounds(latticeSize);
  return PlacedNode(
    id: node.id,
    title: node.title,
    depth: node.depth,
    distance: node.distance,
    kind: node.kind,
    role: node.role,
    description: node.description,
    radius: latticeSize,
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
    // Soft pastel blue / green / red / yellow-orange;
    // lighter grey focus; mid grey for neighbors-of-neighbors.
    NodeRole.parent => dark ? const Color(0xFF2C455C) : const Color(0xFFB9D4F0),
    NodeRole.focus => dark ? const Color(0xFF4A4E55) : const Color(0xFFE8EAEE),
    NodeRole.sibling => dark ? const Color(0xFF5A3038) : const Color(0xFFEBB8C0),
    NodeRole.child => dark ? const Color(0xFF2A453C) : const Color(0xFFB6E2D2),
    NodeRole.related => dark ? const Color(0xFF5A4528) : const Color(0xFFF0C99A),
    NodeRole.extended => dark ? const Color(0xFF3C4046) : const Color(0xFFD8DCE2),
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
    final lattice = math.min(rect.width / 2, rect.height / math.sqrt(3));
    return flatHexPath(lattice * (1 - hexGapInset), center: rect.center);
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
    final lattice = math.min(rect.width / 5, rect.height / (3 * math.sqrt(3)));
    return hexFlowerPath(latticeSize: lattice, center: rect.center);
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;
}
