import 'package:adaptive_mastery/features/knowledge_graph/graph_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('separate topics sit in separate frames', () {
    final layout = layoutGraph(
      ['a', 'b', 'c', 'd'],
      [
        const GraphEdge(from: 'a', to: 'b', type: 'contains'),
        const GraphEdge(from: 'c', to: 'd', type: 'prerequisite'),
      ],
    );
    final point = {for (final item in layout.points) item.id: item};

    expect(layout.frames, hasLength(2));
    expect(point['a']!.component, point['b']!.component);
    expect(point['c']!.component, isNot(point['a']!.component));
    expect(point['b']!.dx, greaterThan(point['a']!.dx));
    expect(point['d']!.dx, greaterThan(point['c']!.dx));
    expect(point['a']!.dy, point['b']!.dy);
    expect(point['c']!.dx, greaterThan(point['b']!.dx + graphNodeWidth));
    expect(_overlaps(layout.frames[0], layout.frames[1]), isFalse);
  });

  test('a related edge keeps those nodes together', () {
    final layout = layoutGraph(
      ['a', 'b', 'c'],
      const [GraphEdge(from: 'a', to: 'b', type: 'related')],
    );
    final point = {for (final item in layout.points) item.id: item};

    expect(point['a']!.component, point['b']!.component);
    expect(point['c']!.component, isNot(point['a']!.component));
    expect(point['b']!.dy, point['a']!.dy);
    expect(point['b']!.dx, greaterThan(point['a']!.dx));
  });

  test('one connected graph stays a single drawing', () {
    final layout = layoutGraph(
      ['a', 'b'],
      const [GraphEdge(from: 'a', to: 'b', type: 'contains')],
    );

    expect(layout.frames, isEmpty);
    expect(layout.points.first.dx, 20);
    expect(layout.points.last.dx, greaterThan(layout.points.first.dx));
  });
}

bool _overlaps(GraphFrame a, GraphFrame b) {
  return a.left < b.left + b.width && a.left + a.width > b.left && a.top < b.top + b.height && a.top + a.height > b.top;
}
