import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'topic_affinity_models.dart';

/// Placeholder height while affinity is loading.
const affinityMapHeight = 160.0;

/// Graph-inspired cluster hues (parent / sibling / child / related / slate).
const _clusterPalette = <Color>[
  Color(0xFF8AAFCF),
  Color(0xFFD98E96),
  Color(0xFF97BF88),
  Color(0xFFDCAD6A),
  Color(0xFFADB3BE),
];

class _RankedTopic {
  const _RankedTopic({
    required this.node,
    required this.neighbors,
    required this.mainScore,
    required this.color,
    required this.rankInCluster,
    required this.clusterSize,
  });

  final TopicAffinityNode node;
  final int neighbors;
  final double mainScore;
  final Color color;
  final int rankInCluster;
  final int clusterSize;
}

class _ClusterGroup {
  const _ClusterGroup({
    required this.color,
    required this.topics,
  });

  final Color color;
  final List<_RankedTopic> topics;
}

/// Sequential topic badges — one hue per cluster, faded by rank.
class TopicAffinityMap extends StatelessWidget {
  const TopicAffinityMap({
    super.key,
    required this.payload,
    required this.onOpenTopic,
  });

  final TopicAffinityPayload payload;
  final ValueChanged<String> onOpenTopic;

  @override
  Widget build(BuildContext context) {
    final groups = _buildGroups(payload);
    if (groups.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < groups.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: groups[i].color.withValues(alpha: 0.34),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final topic in groups[i].topics)
                    _TopicBadge(
                      key: ValueKey(topic.node.id),
                      title: topic.node.name,
                      rank: topic.node.rank,
                      affinity: topic.node.affinity,
                      breakdown: topic.node.breakdown,
                      isMain: topic.rankInCluster == 0,
                      color: _fadeColor(
                        topic.color,
                        topic.rankInCluster,
                        topic.clusterSize,
                        scheme.surface,
                      ),
                      ink: _inkFor(
                        topic.color,
                        topic.rankInCluster,
                        topic.clusterSize,
                        scheme,
                      ),
                      onTap: () => onOpenTopic(topic.node.id),
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

List<_ClusterGroup> _buildGroups(TopicAffinityPayload payload) {
  if (payload.nodes.isEmpty) return const [];

  final byId = {for (final node in payload.nodes) node.id: node};
  final degree = <String, int>{for (final id in byId.keys) id: 0};
  for (final edge in payload.edges) {
    if (!byId.containsKey(edge.source) || !byId.containsKey(edge.target)) {
      continue;
    }
    if (byId[edge.source]!.clusterId != byId[edge.target]!.clusterId) continue;
    degree[edge.source] = (degree[edge.source] ?? 0) + 1;
    degree[edge.target] = (degree[edge.target] ?? 0) + 1;
  }

  final clusters = [...payload.clusters]
    ..sort((a, b) => b.totalAffinity.compareTo(a.totalAffinity));
  final kept = clusters.take(4).toList();
  final groups = <_ClusterGroup>[];

  for (var i = 0; i < kept.length; i++) {
    final cluster = kept[i];
    final color = _clusterPalette[i % _clusterPalette.length];
    final members = [
      for (final id in cluster.nodeIds)
        if (byId[id] != null) byId[id]!,
    ];
    if (members.isEmpty) continue;

    final ranked = <({TopicAffinityNode node, int neighbors, double mainScore})>[
      for (final node in members)
        (
          node: node,
          neighbors: degree[node.id] ?? 0,
          mainScore: node.affinity + 2.0 * (degree[node.id] ?? 0),
        ),
    ]..sort((a, b) {
        final byScore = b.mainScore.compareTo(a.mainScore);
        if (byScore != 0) return byScore;
        return b.node.affinity.compareTo(a.node.affinity);
      });

    final cap = math.min(ranked.length, ranked.length <= 3 ? ranked.length : 6);
    final visible = ranked.take(cap).toList();
    final main = visible.first.mainScore;
    final threshold = main * 0.28;
    final filtered = [
      visible.first,
      for (final row in visible.skip(1))
        if (row.mainScore >= threshold || row.neighbors > 0) row,
    ];

    groups.add(
      _ClusterGroup(
        color: color,
        topics: [
          for (var r = 0; r < filtered.length; r++)
            _RankedTopic(
              node: filtered[r].node,
              neighbors: filtered[r].neighbors,
              mainScore: filtered[r].mainScore,
              color: color,
              rankInCluster: r,
              clusterSize: filtered.length,
            ),
        ],
      ),
    );
  }
  return groups;
}

Color _fadeColor(Color base, int index, int total, Color surface) {
  if (total <= 1) return base;
  final t = index / (total - 1);
  return Color.lerp(base, surface, 0.12 + 0.62 * t)!;
}

Color _inkFor(Color base, int index, int total, ColorScheme scheme) {
  final fill = _fadeColor(base, index, total, scheme.surface);
  final luminance = fill.computeLuminance();
  if (index == 0) {
    return luminance > 0.55 ? const Color(0xFF1C1F24) : Colors.white;
  }
  return scheme.onSurface.withValues(alpha: 0.88 - 0.18 * (index / math.max(1, total - 1)));
}

String _compactScore(double value) {
  if (value == 0) return '0';
  if (value >= 10) return value.toStringAsFixed(0);
  // Keep two decimals so total matches i+n+r (e.g. 0.01+0.15+1.00 → 1.16).
  final two = value.toStringAsFixed(2);
  if (two.endsWith('00')) return value.toStringAsFixed(0);
  if (two.endsWith('0')) return value.toStringAsFixed(1);
  return two;
}

String _breakdownLine(TopicAffinityBreakdown b) {
  final parts = <String>[
    'i${_compactScore(b.interest)}',
    'n${_compactScore(b.neighbor)}',
    'r${_compactScore(b.recency)}',
  ];
  return parts.join(' · ');
}

class _TopicBadge extends StatelessWidget {
  const _TopicBadge({
    super.key,
    required this.title,
    required this.rank,
    required this.affinity,
    required this.breakdown,
    required this.isMain,
    required this.color,
    required this.ink,
    required this.onTap,
  });

  final String title;
  final int rank;
  final double affinity;
  final TopicAffinityBreakdown breakdown;
  final bool isMain;
  final Color color;
  final Color ink;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final muted = ink.withValues(alpha: 0.72);
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(isMain ? 16 : 14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(isMain ? 16 : 14),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: isMain ? 12 : 10,
            vertical: isMain ? 9 : 7,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    rank > 0 ? '#$rank' : '·',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: isMain ? 12 : 11,
                      height: 1.1,
                      color: muted,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 148),
                    child: Text(
                      title,
                      softWrap: true,
                      style: TextStyle(
                        fontFamily: 'tt_ramilas',
                        fontWeight: isMain ? FontWeight.w700 : FontWeight.w600,
                        fontSize: isMain ? 15 : 13,
                        height: 1.15,
                        color: ink,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _compactScore(affinity),
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: isMain ? 12.5 : 11.5,
                      height: 1.1,
                      color: ink,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                _breakdownLine(breakdown),
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.15,
                  fontWeight: FontWeight.w500,
                  color: muted,
                  letterSpacing: 0.15,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
