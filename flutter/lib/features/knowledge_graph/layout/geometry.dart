import 'dart:math' as math;

import 'package:flutter/material.dart';

Offset axialToPixel(int q, int r, double size) {
  final x = size * (3 / 2) * q;
  final y = size * (math.sqrt(3) / 2 * q + math.sqrt(3) * r);
  return Offset(x, y);
}


/// Equal inset so unit hexes (and the flower outline) leave a thin strip.
const hexGapInset = 0.08;

/// Flat-top axial cells for the 7-hex focus flower (center + six around).
const flowerCells = <(int, int)>[
  (0, 0), // center
  (1, 0),
  (1, -1),
  (0, -1),
  (-1, 0),
  (-1, 1),
  (0, 1),
];

/// Pixel centroid of [flowerCells] for lattice size 1 (outline is shifted by this).
final Offset flowerCentroidUnit = () {
  var sx = 0.0;
  var sy = 0.0;
  for (final cell in flowerCells) {
    final p = axialToPixel(cell.$1, cell.$2, 1.0);
    sx += p.dx;
    sy += p.dy;
  }
  return Offset(sx / flowerCells.length, sy / flowerCells.length);
}();

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

/// Outer boundary of the 7-hex flower, origin-centered on the cell centroid.
List<Offset> hexFlowerOutline(double R) {
  final counts = <String, int>{};
  final ends = <String, (Offset, Offset)>{};
  final origin = flowerCentroidUnit * R;

  String edgeKey(Offset a, Offset b) {
    final ka = _pointKey(a);
    final kb = _pointKey(b);
    return ka.compareTo(kb) <= 0 ? '$ka|$kb' : '$kb|$ka';
  }

  for (final cell in flowerCells) {
    final c = axialToPixel(cell.$1, cell.$2, R) - origin;
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

/// Solid 4-cell focus: full lattice outline, parallel-inset by the unit-hex flat
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
    final origin = flowerCentroidUnit * latticeSize;
    Path? solid;
    for (final cell in flowerCells) {
      final c = center + axialToPixel(cell.$1, cell.$2, latticeSize) - origin;
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
  final outline = hexFlowerOutline(unitRadius);
  var minX = double.infinity;
  var maxX = -double.infinity;
  var minY = double.infinity;
  var maxY = -double.infinity;
  for (final v in outline) {
    minX = math.min(minX, v.dx);
    maxX = math.max(maxX, v.dx);
    minY = math.min(minY, v.dy);
    maxY = math.max(maxY, v.dy);
  }
  return Size(math.max(maxX - minX, 1.0), math.max(maxY - minY, 1.0));
}


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
    final unit = hexFlowerBounds(1.0);
    final lattice = math.min(rect.width / unit.width, rect.height / unit.height);
    return hexFlowerPath(latticeSize: lattice, center: rect.center);
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;
}
