import 'dart:math' as math;

import 'package:adaptive_mastery/features/knowledge_graph/graph_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('world layout keeps equal hexes on axial coords', () {
    final layout = layoutWorld(
      const [
        GraphNode(id: 'root', title: 'Science', depth: 0, q: 0, r: 0),
        GraphNode(id: 'child', title: 'Biology', depth: 1, q: 1, r: 0),
      ],
      viewport: const Size(390, 700),
      hexRadius: 40,
    );
    final byId = {for (final node in layout.nodes) node.id: node};
    expect(byId['root']!.isFlower, isFalse);
    expect(byId['child']!.width, closeTo(byId['root']!.width, 0.01));
    expect(byId['child']!.q, 1);
    expect(byId['child']!.r, 0);
    expect(hitTestNode(layout, byId['root']!.center), 'root');
  });

  test('focus is a solid 7-hex flower with parallel outer inset', () {
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
    expect(
      hitTestNode(layout, byId['2']!.center + axialToPixel(1, 0, byId['2']!.radius) * 0.5),
      '2',
    );

    const R = 40.0;
    final outline = hexFlowerOutline(R);
    expect(outline.length, 18);

    final full = Path()
      ..fillType = PathFillType.nonZero
      ..addPolygon(outline, true);
    final flower = hexFlowerPath(latticeSize: R);
    expect(flower.contains(Offset.zero), isTrue);
    expect(flower.contains(axialToPixel(1, 0, R) * 0.5), isTrue);

    // Inset shrinks the silhouette uniformly by ~hexFlatInset on every edge.
    final fullBounds = full.getBounds();
    final insetBounds = flower.getBounds();
    final expected = hexFlatInset(R);
    expect(fullBounds.width - insetBounds.width, closeTo(expected * 2, expected * 0.35));
    expect(fullBounds.height - insetBounds.height, closeTo(expected * 2, expected * 0.35));

    // Clearance from flower to ring-2 hexes is equal across the six directions:
    // measure how far past the flower the lattice neighbor center sits, minus unit radius.
    final drawn = R * (1 - hexGapInset);
    final ring2 = [(2, 0), (2, -2), (0, -2), (-2, 0), (-2, 2), (0, 2)];
    final clearances = <double>[];
    for (final cell in ring2) {
      final neighbor = axialToPixel(cell.$1, cell.$2, R);
      final dir = neighbor / neighbor.distance;
      var lo = 0.0;
      var hi = neighbor.distance;
      for (var i = 0; i < 48; i++) {
        final mid = (lo + hi) / 2;
        if (flower.contains(dir * mid)) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      // Distance from flower boundary to neighbor center, minus neighbor circumradius
      // (= gap along that ray to the neighbor "vertex toward center" approximation).
      clearances.add(neighbor.distance - lo - drawn);
    }
    final mean = clearances.reduce((a, b) => a + b) / clearances.length;
    for (final c in clearances) {
      expect((c - mean).abs(), lessThan(0.35));
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
    // Each extended sits next to its via (within ~one hex step), not the other child.
    expect(dist(byId['ext-a1']!, childA), lessThan(step * 1.15));
    expect(dist(byId['ext-a2']!, childA), lessThan(step * 1.15));
    expect(dist(byId['ext-b1']!, childB), lessThan(step * 1.15));
    expect(dist(byId['ext-a1']!, childA), lessThan(dist(byId['ext-a1']!, childB)));
    expect(dist(byId['ext-a2']!, childA), lessThan(dist(byId['ext-a2']!, childB)));
    expect(dist(byId['ext-b1']!, childB), lessThan(dist(byId['ext-b1']!, childA)));
  });
}
