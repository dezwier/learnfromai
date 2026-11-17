import 'package:adaptive_mastery/features/knowledge_graph/layout/geometry.dart';
import 'package:adaptive_mastery/features/knowledge_graph/layout/graph_layout.dart';
import 'package:flutter/material.dart';

void main() {
  final path = hexFlowerPath(latticeSize: 40);
  final bounds = path.getBounds();
  print('bounds=$bounds empty=${bounds.isEmpty}');
  print('contains origin=${path.contains(Offset.zero)}');
  print('metrics=${path.computeMetrics().length}');
  for (final m in path.computeMetrics()) {
    print('contour len=${m.length} closed=${m.isClosed}');
  }

  // Layout with focus
  final layout = layoutGraph(
    const [
      GraphNode(id: '1', title: 'Parent', depth: -1, kind: 'parent'),
      GraphNode(id: '2', title: 'Focus', depth: 0, kind: 'focus', description: 'Desc'),
      GraphNode(id: '3', title: 'Child', depth: 1, kind: 'child'),
    ],
    const [],
    focusId: '2',
    viewport: const Size(390, 700),
  );
  for (final n in layout.nodes) {
    print('${n.id} flower=${n.isFlower} x=${n.x.toStringAsFixed(1)} y=${n.y.toStringAsFixed(1)} w=${n.width.toStringAsFixed(1)} h=${n.height.toStringAsFixed(1)}');
  }
}
