import 'package:adaptive_mastery/features/knowledge_graph/cluster_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('level 1 domains are separate colored clusters', () {
    final map = layoutClusters(
      [
        {'concept_id': 'life', 'title': 'Life sciences', 'level': 1},
        {'concept_id': 'dinos', 'title': 'Dinosaurs', 'level': 2},
        {'concept_id': 'skills', 'title': 'Life skills', 'level': 1},
        {'concept_id': 'parents', 'title': 'Parenting', 'level': 2},
      ],
      [
        {
          'from_concept_id': 'life',
          'to_concept_id': 'dinos',
          'type': 'contains',
        },
        {
          'from_concept_id': 'skills',
          'to_concept_id': 'parents',
          'type': 'contains',
        },
      ],
    );
    final life = map.labels.firstWhere((label) => label.nodeId == 'life');
    final skills = map.labels.firstWhere((label) => label.nodeId == 'skills');
    final dinos = map.hexes.where((hex) => hex.nodeId == 'dinos');
    final parents = map.hexes.where((hex) => hex.nodeId == 'parents');

    expect(life.color, isNot(skills.color));
    expect(dinos, isNotEmpty);
    expect(parents, isNotEmpty);
    expect(dinos.first.color, life.color);
    expect(parents.first.color, skills.color);
    expect(
      (life.cx - skills.cx).abs() + (life.cy - skills.cy).abs(),
      greaterThan(clusterHexRadius * 8),
    );
  });

  test('a level 3 part is a hexagon inside its domain', () {
    final map = layoutClusters(
      [
        {'concept_id': 'life', 'title': 'Life sciences', 'level': 1},
        {'concept_id': 'dinos', 'title': 'Dinosaurs', 'level': 2},
        {'concept_id': 'teeth', 'title': 'Teeth of dinosaurs', 'level': 3},
      ],
      [
        {
          'from_concept_id': 'life',
          'to_concept_id': 'dinos',
          'type': 'contains',
        },
        {
          'from_concept_id': 'dinos',
          'to_concept_id': 'teeth',
          'type': 'contains',
        },
      ],
    );
    final teeth = map.hexes.where((hex) => hex.nodeId == 'teeth').toList();
    final life = map.labels.firstWhere((label) => label.nodeId == 'life');
    final dinos = map.labels.firstWhere((label) => label.nodeId == 'dinos');

    expect(teeth, hasLength(1));
    expect(teeth.single.color, life.color);
    expect(dinos.level, 2);
    expect(map.labels.firstWhere((label) => label.nodeId == 'teeth').level, 3);
    expect(map.hexes.where((hex) => hex.nodeId == 'dinos'), isEmpty);
    expect(map.hexes.length, greaterThan(1));
  });
}
