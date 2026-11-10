import 'package:adaptive_mastery/features/knowledge_graph/graph_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mosaic fills the viewport with focus center and roles around it', () {
    const viewport = Size(390, 700);
    final layout = layoutGraph(
      const [
        GraphNode(id: '1', title: 'Reptile', depth: -1, kind: 'parent'),
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
      ],
      const [],
      focusId: '2',
      viewport: viewport,
    );

    final byId = {for (final node in layout.nodes) node.id: node};
    expect(byId.keys, {'1', '2', '3', '4', '5', '6'});
    expect(layout.width, viewport.width);
    expect(layout.height, viewport.height);
    expect(byId['1']!.y < byId['2']!.y, isTrue);
    expect(byId['2']!.y < byId['3']!.y, isTrue);
    expect(byId['2']!.description, 'Extinct reptiles from the Mesozoic.');
    expect(byId['5']!.role, NodeRole.sibling);
    expect(byId['6']!.role, NodeRole.related);
    // Focus is the large central tile.
    expect(byId['2']!.width > byId['5']!.width, isTrue);
    expect(byId['2']!.height > byId['1']!.height, isTrue);
    expect(hitTestNode(layout, Offset(byId['3']!.x + 4, byId['3']!.y + 4)), '3');
  });
}
