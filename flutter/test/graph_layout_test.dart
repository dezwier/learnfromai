import 'package:adaptive_mastery/features/knowledge_graph/graph_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parents sit above the focus and children sit below', () {
    final layout = layoutHierarchy(
      const [
        HierarchyNode(id: 1, title: 'Paleontology', depth: -1),
        HierarchyNode(id: 2, title: 'Dinosaurs', depth: 0),
        HierarchyNode(id: 3, title: 'Saurischia', depth: 1),
        HierarchyNode(id: 4, title: 'Ornithischia', depth: 1),
      ],
      const [
        HierarchyEdge(source: 1, target: 2),
        HierarchyEdge(source: 2, target: 3),
        HierarchyEdge(source: 2, target: 4),
      ],
    );
    final point = {for (final node in layout.nodes) node.id: node};

    expect(point[1]!.dy, lessThan(point[2]!.dy));
    expect(point[2]!.dy, lessThan(point[3]!.dy));
    expect(point[3]!.dy, point[4]!.dy);
    expect(point[3]!.dx, isNot(point[4]!.dx));
    final focusCenter = point[2]!.dx + hierarchyNodeWidth / 2;
    final left = point[3]!.dx < point[4]!.dx ? point[3]!.dx : point[4]!.dx;
    final right = (point[3]!.dx > point[4]!.dx ? point[3]!.dx : point[4]!.dx) + hierarchyNodeWidth;
    expect(focusCenter, closeTo((left + right) / 2, 1));
    expect(layout.edges, hasLength(3));
  });

  test('two parents share the row above the focus', () {
    final layout = layoutHierarchy(
      const [
        HierarchyNode(id: 1, title: 'Biology', depth: -1),
        HierarchyNode(id: 2, title: 'Paleontology', depth: -1),
        HierarchyNode(id: 3, title: 'Dinosaurs', depth: 0),
      ],
      const [
        HierarchyEdge(source: 1, target: 3),
        HierarchyEdge(source: 2, target: 3),
      ],
    );
    final point = {for (final node in layout.nodes) node.id: node};

    expect(point[1]!.dy, point[2]!.dy);
    expect(point[1]!.dy, lessThan(point[3]!.dy));
    expect(layout.edges, hasLength(2));
  });

  test('show more keeps extra children out until the parent is expanded', () {
    final nodes = [
      const HierarchyNode(id: 1, title: 'Dinosaurs', depth: 0),
      for (var index = 0; index < 7; index++) HierarchyNode(id: 10 + index, title: 'Child $index', depth: 1),
    ];
    final edges = [for (var index = 0; index < 7; index++) HierarchyEdge(source: 1, target: 10 + index)];
    final collapsed = layoutHierarchy(nodes, edges);
    final expanded = layoutHierarchy(nodes, edges, expanded: {1});

    expect(collapsed.nodes, hasLength(1 + hierarchyChildLimit));
    expect(collapsed.anchors, hasLength(1));
    expect(collapsed.anchors.single.hidden, 1);
    expect(collapsed.nodes.map((node) => node.id), isNot(contains(16)));
    expect(expanded.nodes, hasLength(8));
    expect(expanded.anchors, isEmpty);
    expect(expanded.edges, hasLength(7));
  });
}
