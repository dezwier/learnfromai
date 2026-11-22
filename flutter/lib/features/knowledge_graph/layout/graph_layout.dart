import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import 'geometry.dart';
import 'title_wrap.dart';

enum NodeRole { parent, focus, sibling, child, related, extended }

class GraphNode {
  const GraphNode({
    required this.id,
    required this.title,
    required this.depth,
    this.distance = 0,
    this.kind = 'focus',
    this.description,
    this.imageUrl,
    this.imageThumbUrl,
  });

  final String id;
  final String title;
  final int depth;
  final int distance;
  final String kind;
  final String? description;
  final String? imageUrl;
  final String? imageThumbUrl;

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
    this.imageUrl,
    this.imageThumbUrl,
    this.viaRole,
    this.opacity = 1,
    this.flowerAmount,
    this.colorFromRole,
    this.colorT = 1,
    this.titleFontSize,
    this.titleLaid,
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
  /// Focus is the solid union of unit hexes (no internal gaps).
  final bool isFlower;
  final String? description;
  final String? imageUrl;
  final String? imageThumbUrl;
  /// For [NodeRole.extended]: role of the direct neighbor this tile hangs off.
  final NodeRole? viaRole;
  /// 0–1 visibility while morphing layouts (departing / arriving tiles).
  final double opacity;
  /// 0 = hex tile, 1 = focus flower; null means use [isFlower].
  final double? flowerAmount;
  /// When set, [nodeFill] lerps from this role’s color toward [role] by [colorT].
  final NodeRole? colorFromRole;
  /// 0 = [colorFromRole] fill, 1 = [role] fill.
  final double colorT;
  /// When set (morph), skip live re-fit — use this stable size + [titleLaid].
  final double? titleFontSize;
  /// Pre-wrapped title for morph (softWrap: false); keeps line breaks fixed.
  final String? titleLaid;

  Offset get center => Offset(x + width / 2, y + height / 2);

  double get drawnRadius => radius * (1 - hexGapInset);

  double get effectiveFlowerAmount => flowerAmount ?? (isFlower ? 1 : 0);

  bool contains(Offset point) {
    final local = point - center;
    if (effectiveFlowerAmount >= 0.5) {
      return pointInHexFlower(local, latticeSize: radius);
    }
    return pointInFlatHex(local, drawnRadius);
  }

  PlacedNode copyWith({
    double? x,
    double? y,
    double? width,
    double? height,
    double? radius,
    bool? isFlower,
    NodeRole? role,
    String? title,
    String? description,
    String? imageUrl,
    String? imageThumbUrl,
    double? opacity,
    double? flowerAmount,
    NodeRole? colorFromRole,
    double? colorT,
    double? titleFontSize,
    String? titleLaid,
  }) {
    return PlacedNode(
      id: id,
      title: title ?? this.title,
      depth: depth,
      distance: distance,
      kind: kind,
      role: role ?? this.role,
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      radius: radius ?? this.radius,
      isFlower: isFlower ?? this.isFlower,
      description: description ?? this.description,
      imageUrl: imageUrl ?? this.imageUrl,
      imageThumbUrl: imageThumbUrl ?? this.imageThumbUrl,
      viaRole: viaRole,
      opacity: opacity ?? this.opacity,
      flowerAmount: flowerAmount ?? this.flowerAmount,
      colorFromRole: colorFromRole ?? this.colorFromRole,
      colorT: colorT ?? this.colorT,
      titleFontSize: titleFontSize ?? this.titleFontSize,
      titleLaid: titleLaid ?? this.titleLaid,
    );
  }
}

class GraphLayout {
  const GraphLayout({
    required this.nodes,
    required this.width,
    required this.height,
    this.edges = const [],
  });

  final List<PlacedNode> nodes;
  final List<GraphEdge> edges;
  final double width;
  final double height;
}

/// Translate every tile so [anchorId]'s center matches [targetCenter].
GraphLayout shiftLayoutToAnchor(GraphLayout layout, String anchorId, Offset targetCenter) {
  PlacedNode? anchor;
  for (final node in layout.nodes) {
    if (node.id == anchorId) {
      anchor = node;
      break;
    }
  }
  if (anchor == null) return layout;
  final delta = targetCenter - anchor.center;
  if (delta.distanceSquared < 0.01) return layout;
  return GraphLayout(
    width: layout.width,
    height: layout.height,
    edges: layout.edges,
    nodes: [
      for (final node in layout.nodes)
        node.copyWith(x: node.x + delta.dx, y: node.y + delta.dy),
    ],
  );
}

PlacedNode lerpPlacedNode(PlacedNode a, PlacedNode b, double t) {
  final tt = t.clamp(0.0, 1.0);
  final flower = lerpDouble(a.effectiveFlowerAmount, b.effectiveFlowerAmount, tt)!;
  // Prefer destination metadata once the tile is mostly the new role, but keep
  // fill color lerping the whole way via [colorFromRole]/[colorT].
  final useTo = tt >= 0.5;
  // Keep a non-empty description across the morph so the UI can fade it with flowerAmount
  // (don't snap the string at t=0.5).
  final descA = (a.description ?? '').trim();
  final descB = (b.description ?? '').trim();
  final description = descB.isNotEmpty
      ? b.description
      : (descA.isNotEmpty ? a.description : null);
  return PlacedNode(
    id: b.id,
    title: useTo ? b.title : a.title,
    depth: b.depth,
    distance: b.distance,
    kind: b.kind,
    role: b.role,
    description: description,
    imageUrl: useTo ? b.imageUrl : a.imageUrl,
    imageThumbUrl: useTo ? b.imageThumbUrl : a.imageThumbUrl,
    viaRole: useTo ? b.viaRole : a.viaRole,
    x: lerpDouble(a.x, b.x, tt)!,
    y: lerpDouble(a.y, b.y, tt)!,
    width: lerpDouble(a.width, b.width, tt)!,
    height: lerpDouble(a.height, b.height, tt)!,
    radius: lerpDouble(a.radius, b.radius, tt)!,
    isFlower: flower >= 0.5,
    opacity: lerpDouble(a.opacity, b.opacity, tt)!,
    flowerAmount: flower,
    colorFromRole: a.role,
    colorT: tt,
    titleFontSize: a.titleFontSize ?? b.titleFontSize,
    titleLaid: a.titleLaid ?? b.titleLaid,
  );
}

PlacedNode _scaledAboutCenter(PlacedNode node, double scale) {
  final s = scale.clamp(0.01, 2.0);
  final cx = node.center.dx;
  final cy = node.center.dy;
  final w = node.width * s;
  final h = node.height * s;
  return node.copyWith(
    width: w,
    height: h,
    radius: node.radius * s,
    x: cx - w / 2,
    y: cy - h / 2,
  );
}

/// Fitted title (size + pre-wrapped lines) for a settled tile.
({String text, double fontSize}) fittedTitle(PlacedNode node) {
  final flower = node.effectiveFlowerAmount >= 0.5;
  final padX = node.radius * (flower ? 0.62 : 0.34) * 2;
  final padY = node.radius * (flower ? 0.58 : 0.24) * 2;
  final maxW = (node.width - padX).clamp(8.0, 4000.0);
  final maxH = (node.height - padY).clamp(8.0, 4000.0);
  final hasDesc = flower && (node.description ?? '').trim().isNotEmpty;
  final titleBudget = hasDesc ? maxH * 0.42 : maxH * (flower ? 0.92 : 1.0);
  final maxFont = flower
      ? (node.radius * 0.5).clamp(17.0, 34.0)
      : (node.radius * 0.32).clamp(11.0, 17.0);
  final minFont = flower ? 13.0 : 10.0;
  return layoutTitle(
    text: node.title,
    style: TextStyle(
      fontFamily: 'tt_ramilas',
      height: flower ? 1.1 : 1.15,
      fontWeight: flower ? FontWeight.w700 : FontWeight.w600,
      fontSize: maxFont,
    ),
    maxWidth: maxW,
    maxHeight: titleBudget,
    maxLines: flower ? 3 : 4,
    minFontSize: minFont,
    maxFontSize: maxFont,
    textScaler: TextScaler.noScaling,
    hyphenateAtMinSize: true,
  );
}

typedef MorphLayoutIndex = ({
  Map<String, PlacedNode> fromById,
  Map<String, PlacedNode> toById,
  List<String> ids,
  Map<String, ({String text, double fontSize})> fromTitle,
  Map<String, ({String text, double fontSize})> toTitle,
});

/// Precomputed id maps + fitted titles for [morphGraphLayouts].
MorphLayoutIndex morphLayoutIndex(GraphLayout from, GraphLayout to) {
  final fromById = {for (final n in from.nodes) n.id: n};
  final toById = {for (final n in to.nodes) n.id: n};
  final ids = [...fromById.keys, ...toById.keys.where((id) => !fromById.containsKey(id))];
  return (
    fromById: fromById,
    toById: toById,
    ids: ids,
    fromTitle: {for (final n in from.nodes) n.id: fittedTitle(n)},
    toTitle: {for (final n in to.nodes) n.id: fittedTitle(n)},
  );
}

/// Morph [from] → [to]. Shared ids lerp (size / flower / color); leavers shrink
/// + fade out; arrivals grow from small + fade in.
///
/// Pass [index] from [morphLayoutIndex] to avoid rebuilding maps every tick.
/// Title sizes: shared keep/lerp fitted sizes; arrivals use destination fit (fade via opacity).
GraphLayout morphGraphLayouts(
  GraphLayout from,
  GraphLayout to,
  double t, {
  MorphLayoutIndex? index,
}) {
  // [t] is already eased by the animation controller — keep geometry linear in t.
  final tt = t.clamp(0.0, 1.0);
  final idx = index ?? morphLayoutIndex(from, to);
  final fromById = idx.fromById;
  final toById = idx.toById;
  final nodes = <PlacedNode>[];
  for (final id in idx.ids) {
    final a = fromById[id];
    final b = toById[id];
    if (a != null && b != null) {
      // Shared: freeze prior wrap + size (no reflow / font-size animation).
      final fit = idx.fromTitle[id]!;
      nodes.add(
        lerpPlacedNode(a, b, tt).copyWith(
          titleFontSize: fit.fontSize,
          titleLaid: fit.text,
        ),
      );
    } else if (a != null) {
      // Leave: shrink slightly and fade; keep outgoing title layout.
      final fit = idx.fromTitle[id]!;
      nodes.add(
        _scaledAboutCenter(a, lerpDouble(1.0, 0.62, tt)!).copyWith(
          opacity: lerpDouble(a.opacity, 0, tt)!,
          titleFontSize: fit.fontSize,
          titleLaid: fit.text,
        ),
      );
    } else if (b != null) {
      // Arrive: fade in at destination fitted title (size fixed while tile grows).
      final fit = idx.toTitle[id]!;
      nodes.add(
        _scaledAboutCenter(b, lerpDouble(0.55, 1.0, tt)!).copyWith(
          opacity: lerpDouble(0, b.opacity, tt)!,
          colorFromRole: b.role,
          colorT: 1,
          titleFontSize: fit.fontSize,
          titleLaid: fit.text,
        ),
      );
    }
  }
  // Hold destination edges once the morph is mostly through (avoids mid-flight snap).
  return GraphLayout(
    nodes: nodes,
    edges: tt < 0.72 ? from.edges : to.edges,
    width: lerpDouble(from.width, to.width, tt)!,
    height: lerpDouble(from.height, to.height, tt)!,
  );
}

/// Edge `type` as stored by the API → display [NodeRole].
NodeRole roleFromRelation(String type) {
  switch (type) {
    case 'parent':
      return NodeRole.parent;
    case 'child':
      return NodeRole.child;
    case 'sibling':
      return NodeRole.sibling;
    case 'acquaintance':
    case 'related':
      return NodeRole.related;
    default:
      return NodeRole.related;
  }
}

NodeRole inverseRelationRole(NodeRole role) {
  return switch (role) {
    NodeRole.parent => NodeRole.child,
    NodeRole.child => NodeRole.parent,
    NodeRole.sibling => NodeRole.sibling,
    NodeRole.related => NodeRole.related,
    NodeRole.extended => NodeRole.related,
    NodeRole.focus => NodeRole.related,
  };
}

String relationSectionLabel(NodeRole role) {
  return switch (role) {
    NodeRole.parent => 'Parents',
    NodeRole.sibling => 'Siblings',
    NodeRole.child => 'Children',
    NodeRole.related => 'Related',
    NodeRole.extended => 'Nearby',
    NodeRole.focus => 'Focus',
  };
}

/// Direct neighbors of [node] for the topic detail screen (no extended / 2-hop).
/// Uses layout roles when [node] is the focus, otherwise edges (inbound inverted).
Map<NodeRole, List<PlacedNode>> relationsFor(
  PlacedNode node,
  GraphLayout layout, {
  String? focusId,
}) {
  const sections = [
    NodeRole.parent,
    NodeRole.sibling,
    NodeRole.child,
    NodeRole.related,
  ];
  final groups = {for (final role in sections) role: <PlacedNode>[]};
  final byId = {for (final n in layout.nodes) n.id: n};
  final seen = <String>{};

  void add(PlacedNode other, NodeRole role) {
    if (other.id == node.id || seen.contains(other.id)) return;
    // Drawer lists only direct neighbors — skip neighbors-of-neighbors.
    if (other.role == NodeRole.extended) return;
    final bucket = role == NodeRole.extended ? NodeRole.related : role;
    if (!groups.containsKey(bucket)) return;
    seen.add(other.id);
    groups[bucket]!.add(other);
  }

  final isFocus = node.id == focusId || node.role == NodeRole.focus;
  if (isFocus) {
    for (final other in layout.nodes) {
      if (other.id == node.id) continue;
      switch (other.role) {
        case NodeRole.parent:
        case NodeRole.sibling:
        case NodeRole.child:
        case NodeRole.related:
          add(other, other.role);
        case NodeRole.extended:
        case NodeRole.focus:
          break;
      }
    }
    return groups;
  }

  for (final edge in layout.edges) {
    if (edge.source == node.id) {
      final other = byId[edge.target];
      if (other == null || other.role == NodeRole.extended) continue;
      add(other, roleFromRelation(edge.type));
    } else if (edge.target == node.id) {
      final other = byId[edge.source];
      if (other == null || other.role == NodeRole.extended) continue;
      add(other, inverseRelationRole(roleFromRelation(edge.type)));
    }
  }

  // Fallback: if edges didn't surface the focus, place it by inverse of this node's role.
  if (focusId != null && !seen.contains(focusId)) {
    final focus = byId[focusId];
    if (focus != null) {
      add(focus, inverseRelationRole(node.role));
    }
  }

  return groups;
}

const graphFocusWidth = 168.0;
const graphFocusHeight = 96.0;
const graphCardWidth = 118.0;
const graphSideGap = 8.0;

/// Tight honeycomb on a flat-top axial lattice.
/// Focus is one solid 7-hex flower; direct neighbors on the first free ring;
/// neighbors-of-neighbors sit next to the direct neighbor they hang off.
GraphLayout layoutGraph(
  List<GraphNode> nodes,
  List<GraphEdge> edges, {
  required String focusId,
  Size viewport = const Size(390, 720),
  int maxExtended = 14,
  int canvasMax = 30,
}) {
  final width = math.max(viewport.width, 280.0);
  final height = math.max(viewport.height, 360.0);
  if (nodes.isEmpty) {
    return GraphLayout(nodes: const [], edges: edges, width: width, height: height);
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
    for (final node in siblings) (node, NodeRole.sibling),
    for (final node in children) (node, NodeRole.child),
    for (final node in related) (node, NodeRole.related),
  ];
  final directIds = {for (final item in directs) item.$1.id};
  // Prefer parent/sibling vias when an extended node touches several directs.
  const viaPreference = [
    NodeRole.parent,
    NodeRole.sibling,
    NodeRole.child,
    NodeRole.related,
  ];
  int viaRank(NodeRole? role) {
    final i = viaPreference.indexOf(role ?? NodeRole.related);
    return i < 0 ? viaPreference.length : i;
  }

  final viaDirect = <String, String>{};
  for (final edge in edges) {
    String? extendedId;
    String? directId;
    if (directIds.contains(edge.source) && byId[edge.target]?.role == NodeRole.extended) {
      directId = edge.source;
      extendedId = edge.target;
    } else if (directIds.contains(edge.target) && byId[edge.source]?.role == NodeRole.extended) {
      directId = edge.target;
      extendedId = edge.source;
    }
    if (extendedId == null || directId == null) continue;
    final current = viaDirect[extendedId];
    if (current == null || viaRank(byId[directId]?.role) < viaRank(byId[current]?.role)) {
      viaDirect[extendedId] = directId;
    }
  }

  // Always place every direct; extended tops up to canvasMax (including focus).
  // If directs alone exceed canvasMax, the canvas grows — directs are never dropped.
  final surroundingSlots = math.max(0, canvasMax - 1);
  final fillerSlots = math.max(
    0,
    math.min(maxExtended, surroundingSlots - directs.length),
  );
  // Round-robin fillers by via role so parents/siblings get outer tiles too.
  final pools = <NodeRole, List<GraphNode>>{
    for (final role in viaPreference) role: <GraphNode>[],
  };
  for (final node in extended) {
    final viaId = viaDirect[node.id];
    final viaRole = viaId == null ? NodeRole.related : (byId[viaId]?.role ?? NodeRole.related);
    final key = viaPreference.contains(viaRole) ? viaRole : NodeRole.related;
    pools[key]!.add(node);
  }
  final fillers = <GraphNode>[];
  while (fillers.length < fillerSlots && pools.values.any((list) => list.isNotEmpty)) {
    for (final role in viaPreference) {
      final bucket = pools[role]!;
      if (bucket.isEmpty) continue;
      fillers.add(bucket.removeAt(0));
      if (fillers.length >= fillerSlots) break;
    }
  }

  // Neighbors sit on ring 2+ (ring 1 is the flower petals).
  final occupied = {for (final c in flowerCells) '${c.$1},${c.$2}'};
  final cellPool = math.max(
    directs.length + fillers.length + 18,
    fillers.isEmpty ? directs.length : canvasMax,
  );
  final cells = [
    for (final cell in _ringCells(fromRing: 2, count: math.max(cellPool, 1)))
      if (!occupied.contains('${cell.q},${cell.r}')) cell,
  ];
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
    final viaRole = anchorId == null ? null : byId[anchorId]?.role;
    var best = -1;
    var bestScore = -9999.0;
    for (var i = 0; i < cells.length; i++) {
      if (used.contains(i)) continue;
      final score = anchor == null
          ? _cellScore(cells[i], NodeRole.extended)
          : _nearAnchorScore(cells[i], anchor, directCells, viaRole: viaRole);
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

  // Unit lattice size = 1. Focus flower is centered on the lattice origin.
  final focusBounds = hexFlowerBounds(1.0);
  final origin = flowerCentroidUnit;
  final centers = <(GraphNode, Offset, bool)>[
    (focusNode, Offset.zero, true),
    for (final a in assignments)
      (a.$1, axialToPixel(a.$2.q, a.$2.r, 1.0) - origin, false),
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

  // Fit focus + ring 2, then push in so outer hexes may sit outside the viewport.
  const pad = 8.0;
  const defaultZoomIn = 1.8;
  final footprintHalf = math.max(5.0, 3 * math.sqrt(3)) / 2;
  final nearHalf = footprintHalf + 2 * math.sqrt(3);
  final fitNear = math.min(
    (width - 2 * pad) / (2 * nearHalf),
    (height - 2 * pad) / (2 * nearHalf),
  );
  final scale = fitNear * defaultZoomIn;

  final contentW = math.max((maxX - minX) * scale, 1.0);
  final contentH = math.max((maxY - minY) * scale, 1.0);
  final canvasW = math.max(width, contentW + 2 * pad);
  var canvasH = math.max(height, contentH + 2 * pad);
  // Graph often spills wider than tall; pad height to match so up/down pan
  // has similar room to left/right when zoomed out.
  final spillX = math.max(0.0, canvasW - width);
  canvasH = math.max(canvasH, height + spillX);
  final ox = canvasW / 2;
  final oy = canvasH / 2;

  final placed = <PlacedNode>[];
  for (final c in centers) {
    final cx = c.$2.dx * scale + ox;
    final cy = c.$2.dy * scale + oy;
    if (c.$3) {
      placed.add(_flower(c.$1, cx: cx, cy: cy, latticeSize: scale));
    } else {
      final viaId = viaDirect[c.$1.id];
      final viaRole = viaId == null ? null : byId[viaId]?.role;
      placed.add(_hex(c.$1, cx: cx, cy: cy, radius: scale, viaRole: viaRole));
    }
  }

  return GraphLayout(nodes: placed, edges: edges, width: canvasW, height: canvasH);
}

class _HexCell {
  const _HexCell(this.q, this.r);

  final int q;
  final int r;

  int get s => -q - r;
  int get ring => (q.abs() + r.abs() + s.abs()) ~/ 2;
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
  // Score against the flower centroid so "above/below/side" match the layout.
  final c = axialToPixel(cell.q, cell.r, 1.0) - flowerCentroidUnit;
  final angle = math.atan2(c.dy, c.dx);
  final north = _angleDist(angle, -math.pi / 2);
  final south = _angleDist(angle, math.pi / 2);
  final east = _angleDist(angle, 0);
  final west = _angleDist(angle, math.pi);
  final ringPenalty = (cell.ring - 1) * 1.5;
  final inNorth = c.dy < -0.2;
  final inSouth = c.dy > 0.2;
  final sideBand = c.dy.abs() < 1.35;
  final inEast = c.dx > 0.45 && sideBand;
  final inWest = c.dx < -0.45 && sideBand;

  return switch (role) {
    NodeRole.parent => 6.0 - north * 2.4 - ringPenalty + (inNorth ? 3.0 : -4.0),
    NodeRole.child => 6.0 - south * 2.4 - ringPenalty + (inSouth ? 3.0 : -4.0),
    NodeRole.sibling =>
      6.0 - math.min(east, west) * 2.2 - ringPenalty + ((inEast || inWest) ? 3.0 : -2.5),
    // Related fills around; keep north mostly for parents.
    NodeRole.related => 3.0 - ringPenalty * 0.45 - (inNorth ? 1.6 : 0) + (inSouth || inEast || inWest ? 0.6 : 0),
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

/// Prefer hexes adjacent to [anchor], outward, uniquely closer to that via,
/// and still in the via role's compass sector (parents up, children down, …).
double _nearAnchorScore(
  _HexCell cell,
  _HexCell anchor,
  Map<String, _HexCell> directCells, {
  NodeRole? viaRole,
}) {
  final dist = _cubeDist(cell, anchor);
  final outwardBoost = cell.ring >= anchor.ring ? 1.2 : -1.0;
  var score = 12.0 - dist * 3.0 + outwardBoost - (cell.ring - 1) * 0.15;
  for (final other in directCells.values) {
    if (other.q == anchor.q && other.r == anchor.r) continue;
    final dOther = _cubeDist(cell, other);
    if (dOther < dist) {
      score -= 5.0;
    } else if (dOther == dist) {
      score -= 2.0;
    }
  }
  if (viaRole != null && viaRole != NodeRole.extended && viaRole != NodeRole.focus) {
    score += _cellScore(cell, viaRole) * 0.4;
  }
  return score;
}

double _angleDist(double a, double b) {
  var d = (a - b).abs() % (2 * math.pi);
  if (d > math.pi) d = 2 * math.pi - d;
  return d;
}

PlacedNode _hex(
  GraphNode node, {
  required double cx,
  required double cy,
  required double radius,
  NodeRole? viaRole,
}) {
  final bounds = flatHexBounds(radius);
  return PlacedNode(
    id: node.id,
    title: node.title,
    depth: node.depth,
    distance: node.distance,
    kind: node.kind,
    role: node.role,
    description: node.description,
    imageUrl: node.imageUrl,
    imageThumbUrl: node.imageThumbUrl,
    viaRole: viaRole,
    // Neighbors-of-neighbors sit quieter than directs.
    opacity: node.role == NodeRole.extended ? 0.48 : 1.0,
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
    imageUrl: node.imageUrl,
    imageThumbUrl: node.imageThumbUrl,
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
    // Light: blue / red / warm green / yellow-orange / greys.
    NodeRole.parent => dark ? const Color(0xFF2C455C) : const Color(0xFF8AAFCF),
    NodeRole.focus => dark ? const Color(0xFF7A808A) : const Color(0xFFB4B8C0),
    NodeRole.sibling => dark ? const Color(0xFF5A3038) : const Color(0xFFD98E96),
    NodeRole.child => dark ? const Color(0xFF2A453C) : const Color(0xFF97BF88),
    NodeRole.related => dark ? const Color(0xFF5A4528) : const Color(0xFFDCAD6A),
    NodeRole.extended => dark ? const Color(0xFF3C4046) : const Color(0xFFADB3BE),
  };
}

Color _fillForRole(NodeRole role, NodeRole? viaRole, ColorScheme scheme) {
  if (role != NodeRole.extended) return roleFill(role, scheme);
  final via = viaRole;
  if (via == null || via == NodeRole.extended || via == NodeRole.focus) {
    return roleFill(NodeRole.extended, scheme);
  }
  final base = roleFill(via, scheme);
  final paper = scheme.brightness == Brightness.dark
      ? const Color(0xFF16181C)
      : const Color(0xFFF4F1EA);
  return Color.lerp(base, paper, 0.58)!;
}

/// Tile fill: extended neighbors inherit their via-neighbor color, faded toward paper.
/// During morph, [PlacedNode.colorFromRole] / [PlacedNode.colorT] blend gradually.
Color nodeFill(PlacedNode node, ColorScheme scheme) {
  final to = _fillForRole(node.role, node.viaRole, scheme);
  final fromRole = node.colorFromRole;
  final t = node.colorT.clamp(0.0, 1.0);
  if (fromRole == null || t >= 1) return to;
  if (t <= 0) return _fillForRole(fromRole, node.viaRole, scheme);
  final from = _fillForRole(fromRole, node.viaRole, scheme);
  return Color.lerp(from, to, t)!;
}

Color roleColor(NodeRole role, ColorScheme scheme) => roleFill(role, scheme);


/// Parse a knowledge-graph API payload into a [GraphLayout].
GraphLayout layoutFromPayload(
  Map<String, dynamic>? payload, {
  required String? focusId,
  required Size viewport,
  int maxExtended = 14,
  int canvasMax = 30,
}) {
  if (payload == null) {
    return GraphLayout(nodes: const [], width: viewport.width, height: viewport.height);
  }
  final nodes = [
    for (final raw in (payload['nodes'] as List?) ?? const [])
      if (raw is Map)
        GraphNode(
          id: raw['id'].toString(),
          title: raw['title']?.toString() ?? '',
          depth: (raw['depth'] as num?)?.toInt() ?? 0,
          distance: (raw['distance'] as num?)?.toInt() ?? 0,
          kind: raw['kind']?.toString() ?? 'focus',
          description: raw['description']?.toString(),
          imageUrl: raw['image_url']?.toString(),
          imageThumbUrl: raw['image_thumb_url']?.toString(),
        ),
  ];
  final edges = [
    for (final raw in (payload['edges'] as List?) ?? const [])
      if (raw is Map)
        GraphEdge(
          source: raw['source'].toString(),
          target: raw['target'].toString(),
          type: raw['type']?.toString() ?? 'child',
        ),
  ];
  final focus = focusId ?? (nodes.isEmpty ? '' : nodes.first.id);
  return layoutGraph(
    nodes,
    edges,
    focusId: focus,
    viewport: viewport,
    maxExtended: maxExtended,
    canvasMax: canvasMax,
  );
}
