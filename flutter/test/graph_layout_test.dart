import 'package:adaptive_mastery/features/knowledge_graph/graph_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parents sit above the focus and children below', () {
    final layout = layoutHierarchy(
      const [
        GraphNode(id: 1, title: 'Reptile', depth: -1, kind: 'parent'),
        GraphNode(id: 2, title: 'Dinosaur', depth: 0, kind: 'focus'),
        GraphNode(id: 3, title: 'Saurischia', depth: 1, kind: 'child'),
        GraphNode(id: 4, title: 'Ornithischia', depth: 1, kind: 'child'),
        GraphNode(id: 5, title: 'Mesozoic', depth: 0, kind: 'related'),
      ],
      const [
        GraphEdge(source: 1, target: 2),
        GraphEdge(source: 2, target: 3, type: 'parent_taxon'),
        GraphEdge(source: 2, target: 4, type: 'parent_taxon'),
        GraphEdge(source: 2, target: 5, type: 'related_to'),
      ],
      focusId: 2,
    );

    final byId = {for (final node in layout.nodes) node.id: node};
    expect(byId.keys, {1, 2, 3, 4});
    expect(byId[1]!.y < byId[2]!.y, isTrue);
    expect(byId[2]!.y < byId[3]!.y, isTrue);
    expect(byId[3]!.y, byId[4]!.y);
    expect(layout.related.map((node) => node.title), ['Mesozoic']);
    expect(hitTestNode(layout, Offset(byId[3]!.x + 4, byId[3]!.y + 4)), 3);
  });
}
