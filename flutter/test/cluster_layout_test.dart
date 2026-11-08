import 'dart:math' as math;

import 'package:adaptive_mastery/features/knowledge_graph/cluster_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('level 1 domains are hexagons packed together', () {
    final map = layoutClusters([
      for (var i = 0; i < 7; i++)
        {'concept_id': 'd$i', 'title': 'Domain $i', 'level': 1},
    ], const []);

    expect(map.hexes, hasLength(7));
    final centroid = _centroid(map.hexes);
    final distances = [
      for (final hex in map.hexes)
        _dist(hex.cx, hex.cy, centroid.dx, centroid.dy),
    ]..sort();
    expect(distances.first, lessThan(1));
    for (final distance in distances.skip(1)) {
      expect(distance, closeTo(distances[1], 0.05));
    }
    _expectHoneycomb(map.hexes);
  });

  test('level 1 domains keep their own color and stay apart', () {
    final map = layoutClusters(
      [
        {'concept_id': 'life', 'title': 'Life sciences', 'level': 1},
        {'concept_id': 'dinos', 'title': 'Dinosaurs', 'level': 2},
        {'concept_id': 'skills', 'title': 'Life skills', 'level': 1},
        {'concept_id': 'parents', 'title': 'Parenting', 'level': 2},
      ],
      [
        {
          'from_concept_id': 'life',
          'to_concept_id': 'dinos',
          'type': 'contains',
        },
        {
          'from_concept_id': 'skills',
          'to_concept_id': 'parents',
          'type': 'contains',
        },
      ],
    );
    final life = _hex(map, 'life');
    final skills = _hex(map, 'skills');
    final dinos = _hex(map, 'dinos');
    final parents = _hex(map, 'parents');

    expect(life.color, isNot(skills.color));
    expect(dinos.color, life.color);
    expect(parents.color, skills.color);
    expect(_contains(life, dinos), isTrue);
    expect(_contains(skills, parents), isTrue);
    expect(_contains(life, skills), isFalse);
    expect(_contains(skills, life), isFalse);
    _expectHoneycomb(map.hexes);
  });

  test('a hexagon splits into the same kind of hexagons', () {
    final map = layoutClusters(
      [
        {'concept_id': 'life', 'title': 'Life sciences', 'level': 1},
        {'concept_id': 'dinos', 'title': 'Dinosaurs', 'level': 2},
        {'concept_id': 'plants', 'title': 'Plants', 'level': 2},
        {'concept_id': 'teeth', 'title': 'Teeth of dinosaurs', 'level': 3},
        {'concept_id': 'claws', 'title': 'Claws', 'level': 3},
        {'concept_id': 'eggs', 'title': 'Eggs', 'level': 3},
        {'concept_id': 'trees', 'title': 'Trees', 'level': 3},
      ],
      [
        _containsEdge('life', 'dinos'),
        _containsEdge('life', 'plants'),
        _containsEdge('dinos', 'teeth'),
        _containsEdge('dinos', 'claws'),
        _containsEdge('dinos', 'eggs'),
        _containsEdge('plants', 'trees'),
      ],
    );
    final life = _hex(map, 'life');
    final dinos = _hex(map, 'dinos');
    final plants = _hex(map, 'plants');
    final teeth = _hex(map, 'teeth');

    expect(map.hexes, hasLength(7));
    expect(life.filledAt(1), isTrue);
    expect(life.filledAt(2), isFalse);
    expect(life.outlineAt(2), isTrue);
    expect(dinos.filledAt(1), isFalse);
    expect(dinos.filledAt(2), isTrue);
    expect(dinos.outlineAt(3), isTrue);
    expect(teeth.filledAt(2), isFalse);
    expect(teeth.filledAt(3), isTrue);
    expect(teeth.outlineAt(3), isFalse);
    expect(_contains(life, dinos), isTrue);
    expect(_contains(life, plants), isTrue);
    expect(_contains(dinos, teeth), isTrue);
    expect(_contains(life, teeth), isTrue);
    expect(_contains(plants, teeth), isFalse);
    expect(map.labels.firstWhere((label) => label.nodeId == 'dinos').level, 2);
    expect(map.labels.firstWhere((label) => label.nodeId == 'teeth').level, 3);
    _expectHoneycomb(map.hexes);
  });

  test('six children sit on a hexagon', () {
    final map = layoutClusters(
      [
        {'concept_id': 'life', 'title': 'Life sciences', 'level': 1},
        for (var i = 0; i < 6; i++)
          {'concept_id': 'c$i', 'title': 'Part $i', 'level': 2},
      ],
      [for (var i = 0; i < 6; i++) _containsEdge('life', 'c$i')],
    );
    final life = _hex(map, 'life');
    final kids = [
      for (final hex in map.hexes)
        if (hex.level == 2) hex,
    ];
    final distances = [
      for (final kid in kids) _dist(kid.cx, kid.cy, life.cx, life.cy),
    ];
    for (final distance in distances) {
      expect(distance, closeTo(distances.first, 0.05));
      expect(_contains(life, kids.first), isTrue);
    }
    _expectHoneycomb(map.hexes);
  });

  test('many children form a hexagon, not a line', () {
    final map = layoutClusters(
      [
        {'concept_id': 'life', 'title': 'Life sciences', 'level': 1},
        {'concept_id': 'solo', 'title': 'Psychology', 'level': 1},
        for (var i = 0; i < 11; i++)
          {'concept_id': 'c$i', 'title': 'Part $i', 'level': 2},
      ],
      [for (var i = 0; i < 11; i++) _containsEdge('life', 'c$i')],
    );
    final life = _hex(map, 'life');
    final solo = _hex(map, 'solo');
    expect(life.radius, closeTo(solo.radius, 0.05));
    final apart = _dist(life.cx, life.cy, solo.cx, solo.cy);
    final touch = (life.radius + solo.radius) * math.cos(math.pi / 6);
    expect(apart, greaterThan(touch));
    expect(apart, lessThan(touch * 1.4));
    final kids = [
      for (final hex in map.hexes)
        if (hex.level == 2) hex,
    ];
    expect(kids, hasLength(11));
    for (final kid in kids) {
      expect(kid.radius, closeTo(kids.first.radius, 0.05));
    }
    var minX = kids.first.cx;
    var maxX = kids.first.cx;
    var minY = kids.first.cy;
    var maxY = kids.first.cy;
    for (final kid in kids.skip(1)) {
      if (kid.cx < minX) minX = kid.cx;
      if (kid.cx > maxX) maxX = kid.cx;
      if (kid.cy < minY) minY = kid.cy;
      if (kid.cy > maxY) maxY = kid.cy;
    }
    final width = math.max(maxX - minX, 1);
    final height = math.max(maxY - minY, 1);
    expect(width / height, lessThan(1.8));
    expect(height / width, lessThan(1.8));
    for (final kid in kids) {
      expect(_contains(life, kid), isTrue);
    }
    _expectHoneycomb(map.hexes);
  });
}

Map<String, dynamic> _containsEdge(String from, String to) {
  return {'from_concept_id': from, 'to_concept_id': to, 'type': 'contains'};
}

ClusterHex _hex(ClusterMap map, String id) {
  return map.hexes.firstWhere((hex) => hex.nodeId == id);
}

Offset _centroid(List<ClusterHex> hexes) {
  var x = 0.0;
  var y = 0.0;
  for (final hex in hexes) {
    x += hex.cx;
    y += hex.cy;
  }
  return Offset(x / hexes.length, y / hexes.length);
}

double _dist(double ax, double ay, double bx, double by) {
  final dx = ax - bx;
  final dy = ay - by;
  return math.sqrt(dx * dx + dy * dy);
}

bool _contains(ClusterHex outer, ClusterHex inner) {
  return _dist(outer.cx, outer.cy, inner.cx, inner.cy) + inner.radius <=
      outer.radius * math.cos(math.pi / 6) + 0.8;
}

void _expectHoneycomb(List<ClusterHex> hexes) {
  for (var i = 0; i < hexes.length; i++) {
    for (var j = i + 1; j < hexes.length; j++) {
      final a = hexes[i];
      final b = hexes[j];
      final dist = _dist(a.cx, a.cy, b.cx, b.cy);
      final aInsideB =
          dist + a.radius <= b.radius * math.cos(math.pi / 6) + 0.8;
      final bInsideA =
          dist + b.radius <= a.radius * math.cos(math.pi / 6) + 0.8;
      final apart = dist + 0.8 >= (a.radius + b.radius) * math.cos(math.pi / 6);
      expect(
        aInsideB || bInsideA || apart,
        isTrue,
        reason:
            '${a.nodeId} and ${b.nodeId} overlap '
            '(dist ${dist.toStringAsFixed(1)}, '
            'radii ${a.radius.toStringAsFixed(1)} and ${b.radius.toStringAsFixed(1)})',
      );
    }
  }
}
