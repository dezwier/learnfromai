import 'dart:math' as math;
import 'dart:ui';

/// A level-1 domain drawn as one colored field of hexagons.
class ClusterMap {
  const ClusterMap({
    required this.hexes,
    required this.labels,
    required this.width,
    required this.height,
  });

  final List<ClusterHex> hexes;
  final List<ClusterLabel> labels;
  final double width;
  final double height;
}

class ClusterHex {
  const ClusterHex({
    required this.cx,
    required this.cy,
    required this.color,
    this.nodeId,
  });

  /// Concept this cell opens. Empty cells only fill out the group.
  final String? nodeId;
  final double cx;
  final double cy;
  final Color color;
}

class ClusterLabel {
  const ClusterLabel({
    required this.nodeId,
    required this.title,
    required this.level,
    required this.cx,
    required this.cy,
    required this.width,
    required this.height,
    required this.color,
  });

  final String nodeId;
  final String title;
  final int level;
  final double cx;
  final double cy;
  final double width;
  final double height;
  final Color color;
}

const clusterHexRadius = 12.0;

const clusterPalette = <Color>[
  Color(0xFF3B82F6),
  Color(0xFFF43F5E),
  Color(0xFFA855F7),
  Color(0xFFEAB308),
  Color(0xFF22C55E),
  Color(0xFFF97316),
  Color(0xFF14B8A6),
  Color(0xFFEC4899),
  Color(0xFF6366F1),
  Color(0xFF84CC16),
  Color(0xFFD97706),
  Color(0xFF06B6D4),
];

class _Axial {
  const _Axial(this.q, this.r);

  final int q;
  final int r;

  @override
  bool operator ==(Object other) =>
      other is _Axial && other.q == q && other.r == r;

  @override
  int get hashCode => Object.hash(q, r);
}

const _dirs = <_Axial>[
  _Axial(1, 0),
  _Axial(1, -1),
  _Axial(0, -1),
  _Axial(-1, 0),
  _Axial(-1, 1),
  _Axial(0, 1),
];

class _Node {
  _Node(this.id, this.title, this.level);

  final String id;
  final String title;
  final int level;
}

class _Cell {
  _Cell(this.axial, this.color, [this.nodeId]);

  final _Axial axial;
  final Color color;
  final String? nodeId;
}

ClusterMap layoutClusters(
  List<Map<String, dynamic>> nodes,
  List<Map<String, dynamic>> edges,
) {
  final byId = <String, _Node>{};
  for (final raw in nodes) {
    final id = raw['concept_id']?.toString();
    if (id == null || id.isEmpty || byId.containsKey(id)) continue;
    byId[id] = _Node(id, raw['title']?.toString() ?? 'Concept', _levelOf(raw));
  }
  if (byId.isEmpty) {
    return const ClusterMap(hexes: [], labels: [], width: 360, height: 240);
  }

  final children = {for (final id in byId.keys) id: <String>[]};
  final parent = <String, String>{};
  for (final edge in edges) {
    if (edge['type']?.toString() != 'contains') continue;
    final from = edge['from_concept_id']?.toString();
    final to = edge['to_concept_id']?.toString();
    if (from == null || to == null || from == to || !byId.containsKey(from) || !byId.containsKey(to)) {
      continue;
    }
    if (parent.containsKey(to)) continue;
    parent[to] = from;
    children[from]!.add(to);
  }

  final roots = [
    for (final id in byId.keys)
      if (!parent.containsKey(id)) id,
  ]..sort();
  final hexes = <ClusterHex>[];
  final labels = <ClusterLabel>[];
  final occupied = <Rect>[];

  for (var index = 0; index < roots.length; index++) {
    final root = roots[index];
    final color = clusterPalette[index % clusterPalette.length];
    final island = _island(root, byId, children, color);
    final bounds = _bounds(island);
    final origin = _place(bounds, occupied);
    occupied.add(bounds.shift(origin));
    for (final cell in island) {
      final pixel = _pixel(cell.axial) + origin;
      hexes.add(
        ClusterHex(
          nodeId: cell.nodeId,
          cx: pixel.dx,
          cy: pixel.dy,
          color: cell.color,
        ),
      );
    }
    labels.addAll(_labels(root, byId, children, island, origin, color));
  }

  return _canvas(hexes, labels);
}

List<_Cell> _island(
  String root,
  Map<String, _Node> byId,
  Map<String, List<String>> children,
  Color color,
) {
  final branches = children[root] ?? const <String>[];
  if (branches.isEmpty) {
    return _flower(const _Axial(0, 0), color, root);
  }
  final blobs = <List<_Cell>>[];
  for (final branch in branches) {
    final members = _hexMembers(branch, byId, children);
    final locals = _spiral(math.max(members.length, 1));
    final cells = <_Cell>[];
    for (var i = 0; i < members.length; i++) {
      cells.add(_Cell(locals[i], color, members[i]));
    }
    blobs.add(
      cells.length < 7
          ? _flower(const _Axial(0, 0), color, members.first)
          : cells,
    );
  }
  return _arrange(blobs);
}

List<String> _hexMembers(
  String branch,
  Map<String, _Node> byId,
  Map<String, List<String>> children,
) {
  final deep = <String>[];
  void walk(String id) {
    final node = byId[id];
    if (node != null && node.level >= 3) deep.add(id);
    for (final child in children[id] ?? const <String>[]) {
      walk(child);
    }
  }

  walk(branch);
  if (deep.isNotEmpty) return deep;
  return [branch];
}

List<_Cell> _flower(_Axial center, Color color, String nodeId) {
  return [
    _Cell(center, color, nodeId),
    for (final dir in _dirs)
      _Cell(_Axial(center.q + dir.q, center.r + dir.r), color),
  ];
}

List<_Cell> _arrange(List<List<_Cell>> blobs) {
  final origins = <_Axial>[];
  for (var i = 0; i < blobs.length; i++) {
    final radius = _radius(blobs[i]) + 1;
    if (i == 0) {
      origins.add(const _Axial(0, 0));
      continue;
    }
    _Axial? chosen;
    for (final candidate in _spiral(180)) {
      var clear = true;
      for (var j = 0; j < origins.length; j++) {
        final limit = radius + _radius(blobs[j]) + 1;
        if (_distance(candidate, origins[j]) < limit) {
          clear = false;
          break;
        }
      }
      if (clear) {
        chosen = candidate;
        break;
      }
    }
    origins.add(chosen ?? _Axial(i * 6, 0));
  }
  final cells = <_Cell>[];
  for (var i = 0; i < blobs.length; i++) {
    for (final cell in blobs[i]) {
      cells.add(
        _Cell(
          _Axial(origins[i].q + cell.axial.q, origins[i].r + cell.axial.r),
          cell.color,
          cell.nodeId,
        ),
      );
    }
  }
  return cells;
}

List<ClusterLabel> _labels(
  String root,
  Map<String, _Node> byId,
  Map<String, List<String>> children,
  List<_Cell> island,
  Offset shift,
  Color color,
) {
  final labels = <ClusterLabel>[];
  labels.add(_label(byId[root]!, _centroid(island, null) + shift, color));

  void walk(String id) {
    for (final child in children[id] ?? const <String>[]) {
      final node = byId[child];
      if (node != null) {
        final anchor =
            _centroid(_cellsFor(island, child, children), null) + shift;
        final nudged = node.level >= 3
            ? anchor + const Offset(0, 14)
            : anchor + const Offset(0, 18);
        labels.add(_label(node, nudged, color));
      }
      walk(child);
    }
  }

  walk(root);
  return labels;
}

List<_Cell> _cellsFor(
  List<_Cell> island,
  String id,
  Map<String, List<String>> children,
) {
  final ids = <String>{id};
  void walk(String current) {
    for (final child in children[current] ?? const <String>[]) {
      ids.add(child);
      walk(child);
    }
  }

  walk(id);
  final cells = [
    for (final cell in island)
      if (cell.nodeId != null && ids.contains(cell.nodeId)) cell,
  ];
  return cells.isEmpty ? island : cells;
}

ClusterLabel _label(_Node node, Offset center, Color color) {
  final width = _labelWidth(node.title, node.level);
  final height = node.level <= 1
      ? 34.0
      : node.level == 2
      ? 28.0
      : 22.0;
  return ClusterLabel(
    nodeId: node.id,
    title: node.title,
    level: node.level,
    cx: center.dx,
    cy: center.dy,
    width: width,
    height: height,
    color: color,
  );
}

double _labelWidth(String title, int level) {
  final size = level <= 1
      ? 15.0
      : level == 2
      ? 13.0
      : 11.0;
  final max = level <= 1
      ? 188.0
      : level == 2
      ? 156.0
      : 120.0;
  return (title.length * size * 0.62 + 28).clamp(76.0, max);
}

ClusterMap _canvas(List<ClusterHex> hexes, List<ClusterLabel> labels) {
  var minX = 0.0;
  var minY = 0.0;
  var maxX = 360.0;
  var maxY = 240.0;
  var started = false;
  void include(double left, double top, double right, double bottom) {
    if (!started) {
      minX = left;
      minY = top;
      maxX = right;
      maxY = bottom;
      started = true;
      return;
    }
    if (left < minX) minX = left;
    if (top < minY) minY = top;
    if (right > maxX) maxX = right;
    if (bottom > maxY) maxY = bottom;
  }

  for (final hex in hexes) {
    include(
      hex.cx - clusterHexRadius,
      hex.cy - clusterHexRadius,
      hex.cx + clusterHexRadius,
      hex.cy + clusterHexRadius,
    );
  }
  for (final label in labels) {
    include(
      label.cx - label.width / 2,
      label.cy - label.height / 2,
      label.cx + label.width / 2,
      label.cy + label.height / 2,
    );
  }
  const margin = 36.0;
  final dx = margin - minX;
  final dy = margin - minY;
  return ClusterMap(
    hexes: [
      for (final hex in hexes)
        ClusterHex(
          nodeId: hex.nodeId,
          cx: hex.cx + dx,
          cy: hex.cy + dy,
          color: hex.color,
        ),
    ],
    labels: [
      for (final label in labels)
        ClusterLabel(
          nodeId: label.nodeId,
          title: label.title,
          level: label.level,
          cx: label.cx + dx,
          cy: label.cy + dy,
          width: label.width,
          height: label.height,
          color: label.color,
        ),
    ],
    width: maxX - minX + margin * 2,
    height: maxY - minY + margin * 2,
  );
}

Rect _bounds(List<_Cell> cells) {
  var minX = 0.0;
  var minY = 0.0;
  var maxX = 0.0;
  var maxY = 0.0;
  for (var i = 0; i < cells.length; i++) {
    final pixel = _pixel(cells[i].axial);
    final left = pixel.dx - clusterHexRadius;
    final top = pixel.dy - clusterHexRadius;
    final right = pixel.dx + clusterHexRadius;
    final bottom = pixel.dy + clusterHexRadius;
    if (i == 0 || left < minX) minX = left;
    if (i == 0 || top < minY) minY = top;
    if (i == 0 || right > maxX) maxX = right;
    if (i == 0 || bottom > maxY) maxY = bottom;
  }
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}

Offset _place(Rect bounds, List<Rect> occupied) {
  if (occupied.isEmpty) return Offset.zero;
  final step = math.max(bounds.width, bounds.height) + clusterHexRadius * 4;
  for (var ring = 1; ring < 24; ring++) {
    for (var turn = 0; turn < ring * 6; turn++) {
      final angle = turn / (ring * 6) * math.pi * 2;
      final origin = Offset(
        math.cos(angle) * step * ring,
        math.sin(angle) * step * ring,
      );
      final moved = bounds.shift(origin).inflate(clusterHexRadius * 3);
      final hits = occupied.any(
        (other) => other.inflate(clusterHexRadius * 3).overlaps(moved),
      );
      if (!hits) return origin;
    }
  }
  return Offset(step * (occupied.length + 1), 0);
}

Offset _centroid(List<_Cell> cells, String? nodeId) {
  final chosen = [
    for (final cell in cells)
      if (nodeId == null || cell.nodeId == nodeId) cell,
  ];
  final sample = chosen.isEmpty ? cells : chosen;
  var x = 0.0;
  var y = 0.0;
  for (final cell in sample) {
    final pixel = _pixel(cell.axial);
    x += pixel.dx;
    y += pixel.dy;
  }
  return Offset(x / sample.length, y / sample.length);
}

Offset _pixel(_Axial cell) {
  return Offset(
    clusterHexRadius * math.sqrt(3) * (cell.q + cell.r / 2),
    clusterHexRadius * 1.5 * cell.r,
  );
}

int _radius(List<_Cell> cells) {
  var radius = 0;
  for (final cell in cells) {
    final distance = _distance(cell.axial, const _Axial(0, 0));
    if (distance > radius) radius = distance;
  }
  return radius;
}

int _distance(_Axial a, _Axial b) {
  final dq = a.q - b.q;
  final dr = a.r - b.r;
  return (dq.abs() + dr.abs() + (dq + dr).abs()) ~/ 2;
}

List<_Axial> _spiral(int count) {
  final cells = <_Axial>[const _Axial(0, 0)];
  if (count <= 1) return cells;
  for (var ring = 1; cells.length < count; ring++) {
    var q = _dirs[4].q * ring;
    var r = _dirs[4].r * ring;
    for (var side = 0; side < 6; side++) {
      for (var step = 0; step < ring; step++) {
        cells.add(_Axial(q, r));
        if (cells.length >= count) return cells;
        q += _dirs[side].q;
        r += _dirs[side].r;
      }
    }
  }
  return cells;
}

int _levelOf(Map<String, dynamic> node) {
  final raw = node['level'];
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse('$raw') ?? 0;
}
