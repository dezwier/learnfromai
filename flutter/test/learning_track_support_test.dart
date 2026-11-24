import 'package:adaptive_mastery/features/knowledge_graph/graph_controller.dart';
import 'package:adaptive_mastery/features/knowledge_graph/models.dart';
import 'package:adaptive_mastery/features/knowledge_graph/ui/learning_track_support.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prefetch generate does not block awaitPrefetch on content job', () async {
    final learningCalls = <String>[];
    final graph = GraphController(
      loader: (path) async {
        if (path.startsWith('/me/learning-next')) {
          learningCalls.add(path);
          if (path.contains('picked_node_id=child')) {
            // Advance: dice empty → fallback ready elsewhere.
            return {
              'status': 'ready',
              'node_id': 'focus',
              'title': 'Focus',
              'pack_index': 2,
              'pack': _pack(2),
              'affinity': 0.0,
              'completed_packs': <int>[],
            };
          }
          // Dice prefetch: empty child → generate.
          return {
            'status': 'generate',
            'node_id': 'child',
            'title': 'Child',
          };
        }
        if (path.contains('/content')) {
          return {
            'node_id': 'child',
            'incomplete': true,
            'band': 'default',
            'recipe_version': 1,
            'pack_count': 0,
            'completed_packs': <int>[],
            'packs': <Map<String, dynamic>>[],
          };
        }
        return <String, dynamic>{};
      },
      poster: (path, {body}) async {
        // expand_content enqueue — never completes in this test.
        return {'job_id': 'job-1', 'pack_index': 1};
      },
      jobLoader: (jobId) async => {
            'id': jobId,
            'job_type': 'expand_content',
            'state': 'running',
            'node_id': 'child',
            'title': 'Child',
          },
    );

    final support = LearningTrackSupport(graph);
    final current = LearningNext(
      status: 'ready',
      nodeId: 'focus',
      title: 'Focus',
      packIndex: 1,
      pack: TopicPack.fromJson(_pack(1)),
    );
    support.schedulePrefetch(
      current,
      focusNodeId: 'focus',
      focusTitle: 'Focus',
    );

    // Must finish without waiting for the background generate to complete.
    await support.awaitPrefetch().timeout(const Duration(seconds: 2));
    expect(support.prefetched, isNotNull);
    expect(support.prefetched!.needsGenerate, isTrue);
    expect(support.prefetched!.nodeId, 'child');
    expect(
      learningCalls.any((p) => p.contains('picked_node_id')),
      isFalse,
      reason: 'prefetch dice must not use advance/picked',
    );
  });
}

Map<String, dynamic> _pack(int index) {
  return {
    'pack_index': index,
    'incomplete': false,
    'title': 'Pack $index',
    'bits': [
      {
        'id': 'l$index',
        'kind': 'learn',
        'pack_index': index,
        'position': 0,
        'body': {'title': 'T', 'markdown': 'm'},
      },
      {
        'id': 'c$index',
        'kind': 'check1',
        'pack_index': index,
        'position': 1,
        'body': {
          'type': 'mc',
          'prompt': 'Q?',
          'choices': ['a', 'b', 'c', 'd'],
          'answer_index': 0,
        },
      },
    ],
  };
}
