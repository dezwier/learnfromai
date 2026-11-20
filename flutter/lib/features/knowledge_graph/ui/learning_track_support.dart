import 'dart:async';

import '../graph_controller.dart';
import '../models.dart';

/// Prefetch + ad-hoc image helpers for [LearningTrackSheet].
class LearningTrackSupport {
  LearningTrackSupport(this._graph);

  final GraphController _graph;
  int _prefetchGen = 0;
  LearningNext? prefetched;
  Future<void>? prefetchInFlight;

  void cancelPrefetch() {
    _prefetchGen += 1;
    prefetched = null;
    prefetchInFlight = null;
  }

  void schedulePrefetch(LearningNext current) {
    final seedId = current.nodeId;
    final packIndex = current.packIndex ?? current.pack?.packIndex;
    if (seedId.isEmpty || packIndex == null || packIndex < 1) return;
    final gen = ++_prefetchGen;
    prefetched = null;
    prefetchInFlight = _graph
        .fetchLearningNext(
          seedId,
          excludeNodeId: seedId,
          excludePackIndex: packIndex,
        )
        .then((next) {
      if (gen != _prefetchGen) return;
      prefetched = next;
      final url = next?.bestImageUrl;
      if (url != null) {
        unawaited(_graph.fetchImageBytes(url, notify: false));
      }
    });
  }

  Future<void> awaitPrefetch() async {
    final pending = prefetchInFlight;
    if (pending != null) await pending;
  }

  static (String?, String?) imageUrlsFromGraph(GraphController graph, String? nodeId) {
    if (nodeId == null) return (null, null);
    final nodes = graph.categoryGraph?['nodes'];
    if (nodes is! List) return (null, null);
    for (final raw in nodes) {
      if (raw is Map && raw['id']?.toString() == nodeId) {
        final url = raw['image_url']?.toString().trim();
        final thumb = raw['image_thumb_url']?.toString().trim();
        return (
          (url == null || url.isEmpty) ? null : url,
          (thumb == null || thumb.isEmpty) ? null : thumb,
        );
      }
    }
    return (null, null);
  }

  /// Resolve image for a topic that may not be in the current neighborhood.
  Future<String?> resolveImageUrl(LearningNext next) async {
    final fromPayload = next.bestImageUrl;
    if (fromPayload != null) {
      unawaited(_graph.fetchImageBytes(fromPayload, notify: false));
      return fromPayload;
    }
    final fromGraph = imageUrlsFromGraph(_graph, next.nodeId);
    final graphUrl = fromGraph.$1 ?? fromGraph.$2;
    if (graphUrl != null) {
      unawaited(_graph.fetchImageBytes(graphUrl, notify: false));
      return graphUrl;
    }
    final meta = await _graph.fetchNodeImageMeta(next.nodeId);
    final url = meta?.imageThumbUrl ?? meta?.imageUrl;
    if (url != null) {
      unawaited(_graph.fetchImageBytes(url, notify: false));
    }
    return url;
  }
}
