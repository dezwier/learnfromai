import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/widgets/pulse_placeholder.dart';
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

  void schedulePrefetch(
    LearningNext current, {
    required String originNodeId,
    String? originTitle,
  }) {
    final seedId = current.nodeId;
    final packIndex = current.packIndex ?? current.pack?.packIndex;
    if (seedId.isEmpty || packIndex == null || packIndex < 1) return;
    if (originNodeId.isEmpty) return;
    final gen = ++_prefetchGen;
    prefetched = null;
    prefetchInFlight = _prefetchBody(
      gen: gen,
      seedId: seedId,
      excludePackIndex: packIndex,
      originNodeId: originNodeId,
      originTitle: originTitle,
    );
  }

  Future<void> _prefetchBody({
    required int gen,
    required String seedId,
    required int excludePackIndex,
    required String originNodeId,
    String? originTitle,
  }) async {
    final next = await _graph.fetchLearningNext(
      seedId,
      excludeNodeId: seedId,
      excludePackIndex: excludePackIndex,
    );
    if (gen != _prefetchGen) return;
    prefetched = next;
    _warmImage(next);
    if (next == null || !next.needsGenerate) return;

    // Always generate for the topic where the track started, not a wandered neighbor.
    final title = (originTitle ?? '').trim().isNotEmpty
        ? originTitle!.trim()
        : (next.title.isEmpty ? 'Topic' : next.title);
    await _graph.enqueueContentForTrack(originNodeId, title: title);
    if (gen != _prefetchGen) return;

    // After generate, pick from the origin (exclude the on-screen pack if it is on origin).
    final excludeOriginPack = seedId == originNodeId ? excludePackIndex : null;
    final ready = await _awaitGeneratedPack(
      gen: gen,
      nodeId: originNodeId,
      seedId: originNodeId,
      excludeNodeId: excludeOriginPack == null ? null : originNodeId,
      excludePackIndex: excludeOriginPack,
    );
    if (gen != _prefetchGen || ready == null) return;
    prefetched = ready;
    _warmImage(ready);
  }

  void _warmImage(LearningNext? next) {
    final url = next?.bestImageUrl;
    if (url != null) {
      unawaited(_graph.fetchImageBytes(url, notify: false));
    }
  }

  /// Wait for the content job, then re-fetch the next pack from [seedId].
  Future<LearningNext?> _awaitGeneratedPack({
    required int gen,
    required String nodeId,
    required String seedId,
    String? excludeNodeId,
    int? excludePackIndex,
  }) async {
    var sawJob = _graph.isJobTypeActive(nodeId, 'expand_content');
    for (var i = 0; i < 180; i++) {
      if (gen != _prefetchGen) return null;
      final active = _graph.isJobTypeActive(nodeId, 'expand_content');
      if (active) {
        sawJob = true;
      } else {
        final again = await _graph.fetchLearningNext(
          seedId,
          excludeNodeId: excludeNodeId,
          excludePackIndex: excludePackIndex,
        );
        if (gen != _prefetchGen) return null;
        if (again != null && again.isReady) return again;
        // Finished a job (or never needed one) but still no pack — stop.
        if (sawJob || i > 0) return again;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    return prefetched;
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

/// Card-sized pulse with an explicit generating label for the topic.
class LearningTrackGeneratingCard extends StatelessWidget {
  const LearningTrackGeneratingCard({
    super.key,
    required this.topicTitle,
    this.progressMessage,
  });

  final String topicTitle;
  final String? progressMessage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final detail = progressMessage?.trim();
    return SizedBox(
      height: 320,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const PulsePlaceholder.image(
              borderRadius: BorderRadius.all(Radius.circular(16)),
            ),
            ColoredBox(
              color: scheme.surface.withValues(alpha: 0.82),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Generating learning',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: scheme.onSurface.withValues(alpha: 0.72),
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      topicTitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'tt_ramilas',
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w700,
                        fontSize: 22,
                        height: 1.2,
                      ),
                    ),
                    if (detail != null && detail.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Text(
                        detail,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: scheme.onSurface.withValues(alpha: 0.58),
                          fontSize: 13,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
