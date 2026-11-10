import 'package:adaptive_mastery/features/knowledge_graph/graph_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parents above, siblings beside, children below, related outward', () {
    final layout = layoutGraph(
      const [
        GraphNode(id: '1', title: 'Reptile', depth: -1, kind: 'parent'),
        GraphNode(id: '2', title: 'Dinosaur', depth: 0, kind: 'focus'),
        GraphNode(id: '3', title: 'Saurischia', depth: 1, kind: 'child'),
        GraphNode(id: '4', title: 'Ornithischia', depth: 1, kind: 'child'),
        GraphNode(id: '5', title: 'Mammals', depth: 0, kind: 'sibling'),
        GraphNode(id: '6', title: 'Mesozoic', depth: 0, kind: 'related'),
      ],
      const [
        GraphEdge(source: '2', target: '1', type: 'parent'),
        GraphEdge(source: '2', target: '3', type: 'child'),
        GraphEdge(source: '2', target: '4', type: 'child'),
        GraphEdge(source: '2', target: '5', type: 'sibling'),
        GraphEdge(source: '2', target: '6', type: 'acquaintance'),
      ],
      focusId: '2',
    );

    final byId = {for (final node in layout.nodes) node.id: node};
    expect(byId.keys, {'1', '2', '3', '4', '5', '6'});
    expect(byId['1']!.y < byId['2']!.y, isTrue);
    expect(byId['2']!.y < byId['3']!.y, isTrue);
    expect(byId['5']!.role, NodeRole.sibling);
    expect(byId['6']!.role, NodeRole.related);
    expect(hitTestNode(layout, Offset(byId['3']!.x + 4, byId['3']!.y + 4)), '3');
  });
}
