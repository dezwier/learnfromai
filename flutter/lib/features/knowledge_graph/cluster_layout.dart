import 'dart:math' as math;
import 'dart:ui';

/// Fractal hexagon map of one shared graph.
///
/// Level-1 domains are hexagons packed together into a larger hexagon.
/// A domain splits into the same kind of hexagons — its children — and each
/// of those splits the same way.
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
    required this.radius,
    required this.level,
    required this.childLevel,
    required this.color,
    this.nodeId,
  });

  final String? nodeId;
  final double cx;
  final double cy;

  /// Center to vertex.
  final double radius;
  final int level;

  /// Detail level at which this hexagon splits into its children.
  /// Leaves use a level past any real node so they stay on screen.
  final int childLevel;
  final Color color;

  bool filledAt(int shown) => level <= shown && shown < childLevel;

  bool outlineAt(int shown) => level < shown && childLevel <= shown;
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

/// Vertex radius of a hexagon with nothing nested inside it.
const clusterHexRadius = 22.0;

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

/// Extra space so neighboring hexagons stay separate honeycombs.
const _packGap = 1.06;

/// Parent hexagon is a little larger than the children it splits into.
const _outlinePad = 1.08;

const _leafSplit = 1000000;

class _Axial {
  const _Axial(this.q, this.r);

  final int q;
  final int r;
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

class _Placed {
  _Placed(this.node, this.color, this.radius, this.childLevel, this.children);

  final _Node node;
  final Color color;
  double radius;
  final int childLevel;
  final List<_Placed> children;
  Offset center = Offset.zero;
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
    if (from == null ||
        to == null ||
        from == to ||
        !byId.containsKey(from) ||
        !byId.containsKey(to)) {
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
  final placed = <_Placed>[];
  for (var index = 0; index < roots.length; index++) {
    final id = roots[index];
    placed.add(
      _layout(
        byId[id]!,
        clusterPalette[index % clusterPalette.length],
        children,
        byId,
        {id},
      ),
    );
  }
  _spread(placed);

  final hexes = <ClusterHex>[];
  final labels = <ClusterLabel>[];
  for (final root in placed) {
    _emit(root, Offset.zero, hexes, labels);
  }
  return _canvas(hexes, labels);
}

_Placed _layout(
  _Node node,
  Color color,
  Map<String, List<String>> children,
  Map<String, _Node> byId,
  Set<String> stack,
) {
  final childIds = [...?children[node.id]]..sort();
  final kids = <_Placed>[];
  for (final id in childIds) {
    if (stack.contains(id)) continue;
    kids.add(_layout(byId[id]!, color, children, byId, {...stack, id}));
  }
  _spread(kids);
  var split = _leafSplit;
  if (kids.isNotEmpty) {
    split = kids.first.node.level;
    for (final kid in kids.skip(1)) {
      if (kid.node.level < split) split = kid.node.level;
    }
    if (split <= node.level) split = node.level + 1;
  }
  return _Placed(
    node,
    color,
    kids.isEmpty ? clusterHexRadius : _enclose(kids),
    split,
    kids,
  );
}

void _emit(
  _Placed node,
  Offset origin,
  List<ClusterHex> hexes,
  List<ClusterLabel> labels,
) {
  final world = origin + node.center;
  hexes.add(
    ClusterHex(
      nodeId: node.node.id,
      cx: world.dx,
      cy: world.dy,
      radius: node.radius,
      level: node.node.level,
      childLevel: node.childLevel,
      color: node.color,
    ),
  );
  labels.add(_label(node.node, world, node.color));
  for (final child in node.children) {
    _emit(child, world, hexes, labels);
  }
}

/// Sibling hexagons match in size, so a split looks like the parent.
/// The fullest subtree keeps the middle of the hexagon.
void _spread(List<_Placed> nodes) {
  if (nodes.isEmpty) return;
  var slot = nodes.first.radius;
  for (final node in nodes.skip(1)) {
    if (node.radius > slot) slot = node.radius;
  }
  final weight = {for (final node in nodes) node: node.radius};
  for (final node in nodes) {
    _fit(node, slot);
  }
  final spots = [..._centers(nodes.length, math.sqrt(3) * slot * _packGap)]
    ..sort((a, b) => a.distance.compareTo(b.distance));
  final ordered = [...nodes]
    ..sort((a, b) {
      final byWeight = weight[b]!.compareTo(weight[a]!);
      if (byWeight != 0) return byWeight;
      return a.node.id.compareTo(b.node.id);
    });
  for (var i = 0; i < ordered.length; i++) {
    ordered[i].center = spots[i];
  }
}

void _fit(_Placed node, double target) {
  if (node.radius <= 0) {
    node.radius = target;
    return;
  }
  final scale = target / node.radius;
  node.radius = target;
  if ((scale - 1).abs() < 0.0001) return;
  for (final child in node.children) {
    _scaleTree(child, scale);
  }
}

void _scaleTree(_Placed node, double scale) {
  node.radius *= scale;
  node.center = Offset(node.center.dx * scale, node.center.dy * scale);
  for (final child in node.children) {
    _scaleTree(child, scale);
  }
}

double _enclose(List<_Placed> kids) {
  var reach = 0.0;
  for (final kid in kids) {
    final vertex = (kid.center.distance + kid.radius) / math.cos(math.pi / 6);
    if (vertex > reach) reach = vertex;
  }
  return reach * _outlinePad;
}

List<Offset> _centers(int count, double step) {
  if (count <= 1) return const [Offset.zero];
  if (count < 6) {
    return _recenter([for (final cell in _spiral(count)) _pixel(cell, step)]);
  }
  if (count == 6) {
    return _recenter(_ringPixels(1, 6, step));
  }
  var ring = 1;
  while (_hexCount(ring) < count) {
    ring++;
  }
  final inner = _hexCount(ring - 1);
  return _recenter([
    ..._disk(ring - 1, step),
    ..._ringPixels(ring, count - inner, step),
  ]);
}

List<Offset> _disk(int ring, double step) {
  return [for (final cell in _spiral(_hexCount(ring))) _pixel(cell, step)];
}

List<Offset> _ringPixels(int ring, int take, double step) {
  if (take <= 0) return const [];
  final cells = _spiral(_hexCount(ring)).sublist(_hexCount(ring - 1));
  if (take >= cells.length) {
    return [for (final cell in cells) _pixel(cell, step)];
  }
  final used = <int>{};
  final picked = <_Axial>[];
  for (var i = 0; i < take; i++) {
    final target = i * cells.length / take;
    var best = 0;
    var bestScore = cells.length.toDouble();
    for (var j = 0; j < cells.length; j++) {
      if (used.contains(j)) continue;
      var delta = (j - target).abs();
      if (delta > cells.length / 2) delta = cells.length - delta;
      if (delta < bestScore) {
        bestScore = delta;
        best = j;
      }
    }
    used.add(best);
    picked.add(cells[best]);
  }
  return [for (final cell in picked) _pixel(cell, step)];
}

List<Offset> _recenter(List<Offset> points) {
  var x = 0.0;
  var y = 0.0;
  for (final point in points) {
    x += point.dx;
    y += point.dy;
  }
  final center = Offset(x / points.length, y / points.length);
  return [for (final point in points) point - center];
}

int _hexCount(int ring) => ring < 0 ? 0 : 3 * ring * (ring + 1) + 1;

ClusterLabel _label(_Node node, Offset center, Color color) {
  return ClusterLabel(
    nodeId: node.id,
    title: node.title,
    level: node.level,
    cx: center.dx,
    cy: center.dy,
    width: _labelWidth(node.title, node.level),
    height: _labelHeight(node.level),
    color: color,
  );
}

double _labelHeight(int level) {
  if (level <= 1) return 34;
  if (level == 2) return 28;
  return 22;
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
      hex.cx - hex.radius,
      hex.cy - hex.radius,
      hex.cx + hex.radius,
      hex.cy + hex.radius,
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
          radius: hex.radius,
          level: hex.level,
          childLevel: hex.childLevel,
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

Offset _pixel(_Axial cell, double step) {
  final size = step / math.sqrt(3);
  return Offset(
    size * math.sqrt(3) * (cell.q + cell.r / 2),
    size * 1.5 * cell.r,
  );
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
