import 'dart:math' as math;

import 'package:adaptive_mastery/features/knowledge_graph/graph_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('focus is a solid 4-hex flower with parallel outer inset', () {
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
    expect(byId['2']!.center.dx, closeTo(layout.width / 2, 0.5));
    expect(byId['2']!.center.dy, closeTo(layout.height / 2, 0.5));
    expect(hitTestNode(layout, byId['2']!.center), '2');
    expect(flowerCells.length, 4);

    const R = 40.0;
    final outline = hexFlowerOutline(R);
    expect(outline.length, greaterThanOrEqualTo(10));

    final full = Path()
      ..fillType = PathFillType.nonZero
      ..addPolygon(outline, true);
    final flower = hexFlowerPath(latticeSize: R);
    expect(flower.contains(Offset.zero), isTrue);

    // Inset shrinks the silhouette uniformly by ~hexFlatInset on every edge.
    final fullBounds = full.getBounds();
    final insetBounds = flower.getBounds();
    final expected = hexFlatInset(R);
    expect(fullBounds.width - insetBounds.width, closeTo(expected * 2, expected * 0.45));
    expect(fullBounds.height - insetBounds.height, closeTo(expected * 2, expected * 0.45));

    // Free ring-1 cells sit outside the flower silhouette (same gap strip as unit hexes).
    final ring1 = [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)];
    final occupied = {for (final c in flowerCells) '${c.$1},${c.$2}'};
    final free = [
      for (final cell in ring1)
        if (!occupied.contains('${cell.$1},${cell.$2}')) cell,
    ];
    expect(free.length, 3);
    for (final cell in free) {
      final neighbor = axialToPixel(cell.$1, cell.$2, R) - flowerCentroidUnit * R;
      expect(flower.contains(neighbor), isFalse);
    }
  });

  test('extended nodes sit next to their via direct neighbor', () {
    const viewport = Size(390, 700);
    final layout = layoutGraph(
      const [
        GraphNode(
          id: 'focus',
          title: 'Dinosaur',
          depth: 0,
          kind: 'focus',
          description: 'Focus',
        ),
        GraphNode(id: 'child-a', title: 'Saurischia', depth: 1, kind: 'child'),
        GraphNode(id: 'child-b', title: 'Ornithischia', depth: 1, kind: 'child'),
        GraphNode(id: 'ext-a1', title: 'Theropoda', depth: 2, kind: 'extended'),
        GraphNode(id: 'ext-a2', title: 'Sauropoda', depth: 2, kind: 'extended'),
        GraphNode(id: 'ext-b1', title: 'Thyreophora', depth: 2, kind: 'extended'),
      ],
      const [
        GraphEdge(source: 'focus', target: 'child-a', type: 'child'),
        GraphEdge(source: 'focus', target: 'child-b', type: 'child'),
        GraphEdge(source: 'child-a', target: 'ext-a1', type: 'child'),
        GraphEdge(source: 'child-a', target: 'ext-a2', type: 'child'),
        GraphEdge(source: 'child-b', target: 'ext-b1', type: 'child'),
      ],
      focusId: 'focus',
      viewport: viewport,
    );

    final byId = {for (final node in layout.nodes) node.id: node};
    expect(byId.containsKey('ext-a1'), isTrue);
    expect(byId.containsKey('ext-a2'), isTrue);
    expect(byId.containsKey('ext-b1'), isTrue);

    double dist(PlacedNode a, PlacedNode b) => (a.center - b.center).distance;

    final childA = byId['child-a']!;
    final childB = byId['child-b']!;
    final step = childA.radius * math.sqrt(3); // flat-top adjacent-center distance
    expect(dist(byId['ext-a1']!, childA), lessThan(step * 1.15));
    expect(dist(byId['ext-a2']!, childA), lessThan(step * 1.15));
    expect(dist(byId['ext-b1']!, childB), lessThan(step * 1.15));
    expect(dist(byId['ext-a1']!, childA), lessThan(dist(byId['ext-a1']!, childB)));
    expect(dist(byId['ext-a2']!, childA), lessThan(dist(byId['ext-a2']!, childB)));
    expect(dist(byId['ext-b1']!, childB), lessThan(dist(byId['ext-b1']!, childA)));
    expect(byId['ext-a1']!.viaRole, NodeRole.child);
    expect(byId['ext-b1']!.viaRole, NodeRole.child);
  });
}
