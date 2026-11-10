import 'dart:math' as math;

import 'package:adaptive_mastery/features/knowledge_graph/graph_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('focus is a solid 7-hex flower with unit neighbors around it', () {
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
    expect(byId['2']!.isFlower, isTrue);
    expect(byId['5']!.isFlower, isFalse);
    expect(byId['2']!.width / byId['5']!.width, closeTo(2.5, 0.05));
    expect(hitTestNode(layout, byId['2']!.center), '2');
    // A petal center inside the flower still hits focus.
    final petal = byId['2']!.center + axialToPixel(1, 0, byId['2']!.radius);
    expect(hitTestNode(layout, petal), '2');

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

    final nodes = layout.nodes;
    for (var i = 0; i < nodes.length; i++) {
      for (var j = i + 1; j < nodes.length; j++) {
        final a = nodes[i];
        final b = nodes[j];
        if (a.isFlower || b.isFlower) continue;
        final dist = (a.center - b.center).distance;
        final minDist = (math.sqrt(3) / 2) * (a.radius + b.radius) * 0.98;
        expect(dist, greaterThan(minDist), reason: '${a.id} overlaps ${b.id}');
      }
    }
  });
}
