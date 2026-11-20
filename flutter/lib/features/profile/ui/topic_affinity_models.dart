class TopicAffinityBreakdown {
  const TopicAffinityBreakdown({
    required this.focus,
    required this.open,
    required this.neighbor,
    required this.fresh,
    required this.recency,
  });

  final double focus;
  final double open;
  final double neighbor;
  final double fresh;
  final double recency;

  factory TopicAffinityBreakdown.fromJson(Map<String, dynamic>? raw) {
    if (raw == null) {
      return const TopicAffinityBreakdown(
        focus: 0,
        open: 0,
        neighbor: 0,
        fresh: 0,
        recency: 1,
      );
    }
    return TopicAffinityBreakdown(
      focus: (raw['focus'] as num?)?.toDouble() ?? 0,
      open: (raw['open'] as num?)?.toDouble() ?? 0,
      neighbor: (raw['neighbor'] as num?)?.toDouble() ?? 0,
      fresh: (raw['new'] as num?)?.toDouble() ?? 0,
      recency: (raw['recency'] as num?)?.toDouble() ?? 1,
    );
  }
}

class TopicAffinityNode {
  const TopicAffinityNode({
    required this.id,
    required this.name,
    required this.rank,
    required this.affinity,
    required this.focusCount,
    required this.openCount,
    required this.learned,
    required this.clusterId,
    required this.breakdown,
    this.imageThumbUrl,
  });

  final String id;
  final String name;
  final int rank;
  final double affinity;
  final int focusCount;
  final int openCount;
  final bool learned;
  final int clusterId;
  final TopicAffinityBreakdown breakdown;
  final String? imageThumbUrl;

  factory TopicAffinityNode.fromJson(Map<String, dynamic> raw) {
    final breakdownRaw = raw['breakdown'];
    return TopicAffinityNode(
      id: raw['id']?.toString() ?? '',
      name: raw['name']?.toString() ?? 'Topic',
      rank: (raw['rank'] as num?)?.toInt() ?? 0,
      affinity: (raw['affinity'] as num?)?.toDouble() ?? 0,
      focusCount: (raw['focus_count'] as num?)?.toInt() ?? 0,
      openCount: (raw['open_count'] as num?)?.toInt() ?? 0,
      learned: raw['learned'] == true,
      clusterId: (raw['cluster_id'] as num?)?.toInt() ?? 0,
      breakdown: TopicAffinityBreakdown.fromJson(
        breakdownRaw is Map ? Map<String, dynamic>.from(breakdownRaw) : null,
      ),
      imageThumbUrl: raw['image_thumb_url']?.toString(),
    );
  }
}

class TopicAffinityCluster {
  const TopicAffinityCluster({
    required this.id,
    required this.seedNodeId,
    required this.totalAffinity,
    required this.nodeIds,
  });

  final int id;
  final String seedNodeId;
  final double totalAffinity;
  final List<String> nodeIds;

  factory TopicAffinityCluster.fromJson(Map<String, dynamic> raw) {
    final ids = raw['node_ids'];
    return TopicAffinityCluster(
      id: (raw['id'] as num?)?.toInt() ?? 0,
      seedNodeId: raw['seed_node_id']?.toString() ?? '',
      totalAffinity: (raw['total_affinity'] as num?)?.toDouble() ?? 0,
      nodeIds: [
        if (ids is List)
          for (final id in ids) id.toString(),
      ],
    );
  }
}

class TopicAffinityEdge {
  const TopicAffinityEdge({
    required this.source,
    required this.target,
    required this.type,
  });

  final String source;
  final String target;
  final String type;

  factory TopicAffinityEdge.fromJson(Map<String, dynamic> raw) {
    return TopicAffinityEdge(
      source: raw['source']?.toString() ?? '',
      target: raw['target']?.toString() ?? '',
      type: raw['type']?.toString() ?? '',
    );
  }
}

class TopicAffinityPayload {
  const TopicAffinityPayload({
    required this.nodes,
    required this.clusters,
    required this.edges,
  });

  final List<TopicAffinityNode> nodes;
  final List<TopicAffinityCluster> clusters;
  final List<TopicAffinityEdge> edges;

  bool get isEmpty => nodes.isEmpty;

  factory TopicAffinityPayload.fromJson(Map<String, dynamic> raw) {
    final nodes = raw['nodes'];
    final clusters = raw['clusters'];
    final edges = raw['edges'];
    return TopicAffinityPayload(
      nodes: [
        if (nodes is List)
          for (final row in nodes)
            if (row is Map) TopicAffinityNode.fromJson(Map<String, dynamic>.from(row)),
      ],
      clusters: [
        if (clusters is List)
          for (final row in clusters)
            if (row is Map) TopicAffinityCluster.fromJson(Map<String, dynamic>.from(row)),
      ],
      edges: [
        if (edges is List)
          for (final row in edges)
            if (row is Map) TopicAffinityEdge.fromJson(Map<String, dynamic>.from(row)),
      ],
    );
  }
}
