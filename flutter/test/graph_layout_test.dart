import 'package:adaptive_mastery/features/knowledge_graph/graph_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const nodes = [
    GraphNode(id: 1, title: 'reptile', depth: -1, distance: 1),
    GraphNode(id: 2, title: 'dinosaur', depth: 0, distance: 0),
    GraphNode(id: 5, title: 'lizard', depth: 0, distance: 2),
    GraphNode(id: 3, title: 'Saurischia', depth: 1, distance: 1),
    GraphNode(id: 4, title: 'Ornithischia', depth: 1, distance: 1),
  ];
  const edges = [
    GraphEdge(source: 1, target: 2),
    GraphEdge(source: 1, target: 5),
    GraphEdge(source: 2, target: 3),
    GraphEdge(source: 2, target: 4),
  ];

  test('zooming in splits the focus into its children', () {
    final merged = layoutHexMap(nodes, edges, focusId: 2, window: const ZoomWindow(climb: 0, expand: 0));
    final split = layoutHexMap(nodes, edges, focusId: 2, window: const ZoomWindow(climb: 0, expand: 1));
    final mergedIds = merged.cells.map((cell) => cell.id).toSet();
    final splitIds = split.cells.map((cell) => cell.id).toSet();

    expect(mergedIds, {2});
    expect(mergedIds, isNot(contains(3)));
    expect(splitIds, containsAll({3, 4}));
    expect(splitIds, isNot(contains(2)));
    expect(split.cells.length, greaterThan(merged.cells.length));
  });

  test('zooming out climbs to the parent and shows siblings', () {
    final close = layoutHexMap(nodes, edges, focusId: 2, window: const ZoomWindow(climb: 0, expand: 1));
    final wide = layoutHexMap(nodes, edges, focusId: 2, window: const ZoomWindow(climb: 1, expand: 1));
    expect(close.cells.map((cell) => cell.id), containsAll({3, 4}));
    expect(wide.cells.map((cell) => cell.id), containsAll({2, 5}));
    expect(wide.cells.map((cell) => cell.id), isNot(contains(1)));
  });

  test('zooming farther out collapses into the parent hex', () {
    final wide = layoutHexMap(nodes, edges, focusId: 2, window: const ZoomWindow(climb: 1, expand: 0));
    expect(wide.cells.single.id, 1);
    expect(wide.cells.single.radius, hexRootRadius);
  });

  test('labels stay a fixed size and hide when a hex is too small', () {
    final roomy = layoutHexMap(
      nodes,
      edges,
      focusId: 2,
      window: const ZoomWindow(climb: 0, expand: 1),
      scale: 3,
      rootRadius: 240,
    );
    final cramped = layoutHexMap(
      nodes,
      edges,
      focusId: 2,
      window: const ZoomWindow(climb: 0, expand: 1),
      scale: 0.2,
      rootRadius: 40,
    );

    expect(roomy.cells.any((cell) => cell.showLabel), isTrue);
    expect(cramped.cells.every((cell) => !cell.showLabel), isTrue);
    expect(hexLabelFontSize, 13);
  });

  test('hit testing returns the smallest hex under a point', () {
    final layout = layoutHexMap(nodes, edges, focusId: 2, window: const ZoomWindow(climb: 0, expand: 1));
    final child = layout.cells.firstWhere((cell) => cell.id == 3);
    expect(hitTestHex(layout, Offset(child.x, child.y)), 3);
  });
}
