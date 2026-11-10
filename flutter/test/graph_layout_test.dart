import 'dart:math' as math;

import 'package:adaptive_mastery/features/knowledge_graph/graph_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('honeycomb packs tight with a 7-cell focus', () {
    const viewport = Size(390, 700);
    final layout = layoutGraph(
      const [
        GraphNode(id: '1', title: 'Reptile', depth: -1, kind: 'parent'),
        GraphNode(id: '1b', title: 'Archosaur', depth: -1, kind: 'parent'),
        GraphNode(
          id: '2',
          title: 'Dinosaur',
          depth: 0,
          kind: 'focus',
          description: 'Extinct reptiles from the Mesozoic.',
        ),
        GraphNode(id: '3', title: 'Saurischia', depth: 1, kind: 'child'),
        GraphNode(id: '4', title: 'Ornithischia', depth: 1, kind: 'child'),
        GraphNode(id: '5', title: 'Mammals', depth: 0, kind: 'sibling'),
        GraphNode(id: '6', title: 'Mesozoic', depth: 0, kind: 'related'),
        GraphNode(id: '7', title: 'Birds', depth: 1, kind: 'child'),
        GraphNode(id: '8', title: 'Thyreophora', depth: 1, kind: 'child'),
      ],
      const [],
      focusId: '2',
      viewport: viewport,
    );

    final byId = {for (final node in layout.nodes) node.id: node};
    expect(byId.keys.length, 9);
    // Parents as a group sit above the focus; children below.
    final parentY = [
      for (final n in layout.nodes)
        if (n.role == NodeRole.parent) n.center.dy,
    ];
    final childY = [
      for (final n in layout.nodes)
        if (n.role == NodeRole.child) n.center.dy,
    ];
    expect(parentY.every((y) => y < byId['2']!.center.dy), isTrue);
    expect(childY.every((y) => y > byId['2']!.center.dy), isTrue);
    // Focus covers 7 unit cells → circumradius 2.5× unit.
    expect(byId['2']!.radius / byId['5']!.radius, closeTo(2.5, 0.01));
    expect(hitTestNode(layout, byId['2']!.center), '2');

    final nodes = layout.nodes;
    for (var i = 0; i < nodes.length; i++) {
      for (var j = i + 1; j < nodes.length; j++) {
        final a = nodes[i];
        final b = nodes[j];
        final dist = (a.center - b.center).distance;
        final minDist = (math.sqrt(3) / 2) * (a.radius + b.radius) * 0.98;
        expect(dist, greaterThan(minDist), reason: '${a.id} overlaps ${b.id}');
      }
    }

    // Neighbor hexes sit nearly edge-to-edge (tiny equal gap only).
    final unit = [for (final n in nodes) if (n.id != '2') n];
    var closest = double.infinity;
    for (var i = 0; i < unit.length; i++) {
      for (var j = i + 1; j < unit.length; j++) {
        closest = math.min(closest, (unit[i].center - unit[j].center).distance);
      }
    }
    final expected = math.sqrt(3) * unit.first.radius / (1 - hexGapInset);
    expect(closest, lessThan(expected * 1.08));
  });
}
