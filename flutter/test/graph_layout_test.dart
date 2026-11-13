import 'dart:math' as math;

import 'package:adaptive_mastery/features/knowledge_graph/graph_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
    expect(flowerCells.length, 7);

    const R = 40.0;
    final outline = hexFlowerOutline(R);
    expect(outline.length, greaterThanOrEqualTo(12));

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

    // Ring 1 is fully occupied by petals; ring-2 cells sit outside the flower.
    final ring1 = [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)];
    final occupied = {for (final c in flowerCells) '${c.$1},${c.$2}'};
    expect(ring1.every((cell) => occupied.contains('${cell.$1},${cell.$2}')), isTrue);
    final ring2 = [(2, 0), (2, -2), (0, -2), (-2, 0), (-2, 2), (0, 2)];
    for (final cell in ring2) {
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

  test('extended fillers round-robin across parent and sibling vias', () {
    const viewport = Size(390, 700);
    final layout = layoutGraph(
      const [
        GraphNode(id: 'focus', title: 'Dinosaur', depth: 0, kind: 'focus'),
        GraphNode(id: 'parent', title: 'Reptile', depth: -1, kind: 'parent'),
        GraphNode(id: 'sibling', title: 'Mammals', depth: 0, kind: 'sibling'),
        GraphNode(id: 'child', title: 'Saurischia', depth: 1, kind: 'child'),
        GraphNode(id: 'related', title: 'Mesozoic', depth: 0, kind: 'related'),
        GraphNode(id: 'ext-p1', title: 'Amniote', depth: 0, kind: 'extended'),
        GraphNode(id: 'ext-p2', title: 'Vertebrate', depth: 0, kind: 'extended'),
        GraphNode(id: 'ext-s1', title: 'Birds', depth: 0, kind: 'extended'),
        GraphNode(id: 'ext-c1', title: 'Theropoda', depth: 0, kind: 'extended'),
        GraphNode(id: 'ext-c2', title: 'Sauropoda', depth: 0, kind: 'extended'),
        GraphNode(id: 'ext-c3', title: 'Ornithischia', depth: 0, kind: 'extended'),
        GraphNode(id: 'ext-r1', title: 'Fossils', depth: 0, kind: 'extended'),
      ],
      const [
        GraphEdge(source: 'focus', target: 'parent', type: 'parent'),
        GraphEdge(source: 'focus', target: 'sibling', type: 'sibling'),
        GraphEdge(source: 'focus', target: 'child', type: 'child'),
        GraphEdge(source: 'focus', target: 'related', type: 'acquaintance'),
        GraphEdge(source: 'parent', target: 'ext-p1', type: 'parent'),
        GraphEdge(source: 'parent', target: 'ext-p2', type: 'parent'),
        GraphEdge(source: 'sibling', target: 'ext-s1', type: 'sibling'),
        GraphEdge(source: 'child', target: 'ext-c1', type: 'child'),
        GraphEdge(source: 'child', target: 'ext-c2', type: 'child'),
        GraphEdge(source: 'child', target: 'ext-c3', type: 'child'),
        GraphEdge(source: 'related', target: 'ext-r1', type: 'acquaintance'),
      ],
      focusId: 'focus',
      viewport: viewport,
    );

    final byId = {for (final node in layout.nodes) node.id: node};
    final viaCounts = <NodeRole, int>{};
    for (final node in layout.nodes) {
      if (node.role != NodeRole.extended) continue;
      final via = node.viaRole;
      if (via == null) continue;
      viaCounts[via] = (viaCounts[via] ?? 0) + 1;
    }
    expect(viaCounts[NodeRole.parent] ?? 0, greaterThanOrEqualTo(1));
    expect(viaCounts[NodeRole.sibling] ?? 0, greaterThanOrEqualTo(1));
    expect(byId.containsKey('ext-p1'), isTrue);
    expect(byId.containsKey('ext-s1'), isTrue);
  });

  test('all directs are placed even when maxExtended is zero', () {
    final layout = layoutGraph(
      const [
        GraphNode(id: 'focus', title: 'Dinosaur', depth: 0, kind: 'focus'),
        GraphNode(id: 'parent', title: 'Reptile', depth: -1, kind: 'parent'),
        GraphNode(id: 'sibling', title: 'Mammals', depth: 0, kind: 'sibling'),
        GraphNode(id: 'child', title: 'Saurischia', depth: 1, kind: 'child'),
        GraphNode(id: 'related', title: 'Mesozoic', depth: 0, kind: 'related'),
        GraphNode(id: 'ext-1', title: 'Outer', depth: 0, kind: 'extended'),
      ],
      const [
        GraphEdge(source: 'child', target: 'ext-1', type: 'child'),
      ],
      focusId: 'focus',
      viewport: const Size(390, 700),
      maxExtended: 0,
    );
    final ids = {for (final node in layout.nodes) node.id};
    expect(ids, containsAll(['focus', 'parent', 'sibling', 'child', 'related']));
    expect(ids.contains('ext-1'), isFalse);
  });

  test('focus morph keeps the new focus anchored and fades leavers', () {
    const viewport = Size(390, 700);
    final from = layoutGraph(
      const [
        GraphNode(id: 'a', title: 'A', depth: 0, kind: 'focus'),
        GraphNode(id: 'b', title: 'B', depth: 1, kind: 'child'),
        GraphNode(id: 'c', title: 'C', depth: 0, kind: 'sibling'),
      ],
      const [],
      focusId: 'a',
      viewport: viewport,
    );
    final to = layoutGraph(
      const [
        GraphNode(id: 'b', title: 'B', depth: 0, kind: 'focus'),
        GraphNode(id: 'a', title: 'A', depth: -1, kind: 'parent'),
        GraphNode(id: 'd', title: 'D', depth: 1, kind: 'child'),
      ],
      const [],
      focusId: 'b',
      viewport: viewport,
    );
    final bTo = to.nodes.firstWhere((n) => n.id == 'b');
    final aligned = shiftLayoutToAnchor(from, 'b', bTo.center);
    final mid = morphGraphLayouts(aligned, to, 0.5);
    final byId = {for (final n in mid.nodes) n.id: n};
    expect(byId['b']!.center.dx, closeTo(bTo.center.dx, 1.0));
    expect(byId['b']!.center.dy, closeTo(bTo.center.dy, 1.0));
    expect(byId['c']!.opacity, lessThan(0.6));
    expect(byId['d']!.opacity, greaterThan(0.4));
    expect(byId['b']!.effectiveFlowerAmount, greaterThan(0.4));
  });
}
