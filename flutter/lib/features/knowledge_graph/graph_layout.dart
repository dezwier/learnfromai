/// Places one shared graph so each connected piece is its own drawing.
class GraphEdge {
  const GraphEdge({required this.from, required this.to, required this.type});

  final String from;
  final String to;
  final String type;
}

class GraphPoint {
  const GraphPoint({required this.id, required this.dx, required this.dy, required this.component});

  final String id;
  final double dx;
  final double dy;
  final int component;
}

class GraphFrame {
  const GraphFrame({required this.left, required this.top, required this.width, required this.height});

  final double left;
  final double top;
  final double width;
  final double height;
}

class GraphLayout {
  const GraphLayout({required this.points, required this.frames, required this.width, required this.height});

  final List<GraphPoint> points;
  final List<GraphFrame> frames;
  final double width;
  final double height;
}

const graphNodeWidth = 168.0;
const graphNodeHeight = 72.0;

const _columnStride = 224.0;
const _rowStride = 112.0;
const _componentGap = 72.0;
const _componentPad = 28.0;
const _canvasMargin = 20.0;
const _wrapWidth = 1280.0;

GraphLayout layoutGraph(List<String> ids, List<GraphEdge> edges) {
  if (ids.isEmpty) {
    return const GraphLayout(points: [], frames: [], width: 360, height: 240);
  }
  final indexOf = <String, int>{};
  for (var i = 0; i < ids.length; i++) {
    indexOf.putIfAbsent(ids[i], () => i);
  }
  final unique = indexOf.keys.toList();
  final parent = {for (final id in unique) id: id};

  String find(String id) {
    var root = id;
    while (parent[root] != root) {
      root = parent[root]!;
    }
    var cursor = id;
    while (cursor != root) {
      final next = parent[cursor]!;
      parent[cursor] = root;
      cursor = next;
    }
    return root;
  }

  void unite(String a, String b) {
    var ra = find(a);
    var rb = find(b);
    if (ra == rb) return;
    if (indexOf[rb]! < indexOf[ra]!) {
      final swap = ra;
      ra = rb;
      rb = swap;
    }
    parent[rb] = ra;
  }

  for (final edge in edges) {
    if (!indexOf.containsKey(edge.from) || !indexOf.containsKey(edge.to) || edge.from == edge.to) continue;
    unite(edge.from, edge.to);
  }

  final groups = <String, List<String>>{};
  for (final id in unique) {
    groups.putIfAbsent(find(id), () => []).add(id);
  }
  final components = groups.values.toList()
    ..sort((a, b) {
      final bySize = b.length.compareTo(a.length);
      if (bySize != 0) return bySize;
      return indexOf[a.first]!.compareTo(indexOf[b.first]!);
    });

  final locals = [for (final component in components) _layoutComponent(component, edges, indexOf)];
  final divided = components.length > 1;
  final pad = divided ? _componentPad : 0.0;
  final gap = divided ? _componentGap : 0.0;
  var cursorX = _canvasMargin;
  var cursorY = _canvasMargin;
  var rowHeight = 0.0;
  final points = <GraphPoint>[];
  final frames = <GraphFrame>[];

  for (var component = 0; component < locals.length; component++) {
    final local = locals[component];
    var maxX = graphNodeWidth;
    var maxY = graphNodeHeight;
    for (final item in local) {
      final right = item.dx + graphNodeWidth;
      final bottom = item.dy + graphNodeHeight;
      if (right > maxX) maxX = right;
      if (bottom > maxY) maxY = bottom;
    }
    final blockWidth = maxX + pad * 2;
    final blockHeight = maxY + pad * 2;
    if (cursorX > _canvasMargin && cursorX + blockWidth > _canvasMargin + _wrapWidth) {
      cursorX = _canvasMargin;
      cursorY += rowHeight + gap;
      rowHeight = 0;
    }
    if (divided) {
      frames.add(GraphFrame(left: cursorX, top: cursorY, width: blockWidth, height: blockHeight));
    }
    for (final item in local) {
      points.add(GraphPoint(id: item.id, dx: cursorX + pad + item.dx, dy: cursorY + pad + item.dy, component: component));
    }
    cursorX += blockWidth + gap;
    if (blockHeight > rowHeight) rowHeight = blockHeight;
  }

  var width = 360.0;
  var height = 240.0;
  for (final point in points) {
    final right = point.dx + graphNodeWidth + _canvasMargin;
    final bottom = point.dy + graphNodeHeight + _canvasMargin;
    if (right > width) width = right;
    if (bottom > height) height = bottom;
  }
  for (final frame in frames) {
    final right = frame.left + frame.width + _canvasMargin;
    final bottom = frame.top + frame.height + _canvasMargin;
    if (right > width) width = right;
    if (bottom > height) height = bottom;
  }
  return GraphLayout(points: points, frames: frames, width: width, height: height);
}

class _LocalPoint {
  const _LocalPoint(this.id, this.dx, this.dy);

  final String id;
  final double dx;
  final double dy;
}

List<_LocalPoint> _layoutComponent(List<String> ids, List<GraphEdge> edges, Map<String, int> indexOf) {
  final members = ids.toSet();
  final children = {for (final id in ids) id: <String>[]};
  final parents = {for (final id in ids) id: <String>[]};
  final related = {for (final id in ids) id: <String>[]};
  final incoming = {for (final id in ids) id: 0};
  final structured = {for (final id in ids) id: false};
  var anyDirected = false;

  for (final edge in edges) {
    if (!members.contains(edge.from) || !members.contains(edge.to) || edge.from == edge.to) continue;
    final directed = edge.type == 'contains' || edge.type == 'prerequisite';
    if (directed) {
      anyDirected = true;
      structured[edge.from] = true;
      structured[edge.to] = true;
      children[edge.from]!.add(edge.to);
      parents[edge.to]!.add(edge.from);
      incoming[edge.to] = incoming[edge.to]! + 1;
    } else {
      related[edge.from]!.add(edge.to);
      related[edge.to]!.add(edge.from);
    }
  }

  final ordered = [...ids]..sort((a, b) => indexOf[a]!.compareTo(indexOf[b]!));
  if (!anyDirected) {
    return [for (var i = 0; i < ordered.length; i++) _LocalPoint(ordered[i], i * _columnStride, 0)];
  }

  final depth = {for (final id in ids) id: 0};
  final queue = <String>[for (final id in ordered) if (incoming[id] == 0) id];
  final seen = <String>{};
  while (queue.isNotEmpty) {
    final id = queue.removeAt(0);
    if (!seen.add(id)) continue;
    for (final child in children[id]!) {
      final next = depth[id]! + 1;
      if (next > depth[child]!) depth[child] = next;
      queue.add(child);
    }
  }

  for (final id in ordered) {
    if (structured[id]!) continue;
    var best = depth[id]!;
    var found = false;
    for (final neighbor in related[id]!) {
      if (!structured[neighbor]!) continue;
      if (!found || depth[neighbor]! < best) {
        best = depth[neighbor]!;
        found = true;
      }
    }
    if (found) depth[id] = best;
  }

  final columns = <int, List<String>>{};
  for (final id in ordered) {
    columns.putIfAbsent(depth[id]!, () => []).add(id);
  }
  final depths = columns.keys.toList()..sort();
  final rowOf = <String, int>{};
  for (final column in depths) {
    final columnIds = columns[column]!;
    columnIds.sort((a, b) {
      final byAnchor = _anchor(a, parents, related, rowOf, indexOf).compareTo(_anchor(b, parents, related, rowOf, indexOf));
      if (byAnchor != 0) return byAnchor;
      return indexOf[a]!.compareTo(indexOf[b]!);
    });
    for (var row = 0; row < columnIds.length; row++) {
      rowOf[columnIds[row]] = row;
    }
  }

  final placed = <_LocalPoint>[];
  for (final column in depths) {
    final columnIds = columns[column]!;
    for (var row = 0; row < columnIds.length; row++) {
      placed.add(_LocalPoint(columnIds[row], column * _columnStride, row * _rowStride));
    }
  }
  return placed;
}

double _anchor(
  String id,
  Map<String, List<String>> parents,
  Map<String, List<String>> related,
  Map<String, int> rowOf,
  Map<String, int> indexOf,
) {
  var sum = 0.0;
  var count = 0;
  for (final other in [...parents[id]!, ...related[id]!]) {
    final row = rowOf[other];
    if (row == null) continue;
    sum += row;
    count += 1;
  }
  if (count == 0) return indexOf[id]!.toDouble();
  return sum / count;
}
