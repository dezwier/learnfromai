/// Shared knowledge-graph models used by [GraphController] and UI.

class TopicChoice {
  const TopicChoice({required this.id, required this.title, this.description});

  final String id;
  final String title;
  final String? description;
}

class FocusTrailEntry {
  const FocusTrailEntry({required this.id, required this.title});

  final String id;
  final String title;
}

/// Backend LLM provider preference: gemini | openai.
class LlmProviderPref {
  static const gemini = 'gemini';
  static const openai = 'openai';

  static String normalize(Object? raw) {
    final value = (raw?.toString() ?? '').trim().toLowerCase();
    if (value == gemini || value == 'google') return gemini;
    return openai;
  }

  static String label(String provider) =>
      provider == openai ? 'ChatGPT' : 'Gemini';
}

/// Global neighborhood sizes (not per-user).
class NeighborhoodPrefs {
  const NeighborhoodPrefs({
    this.total = defaultTotal,
    this.extended = defaultExtended,
    this.canvasMax = defaultCanvasMax,
  });

  static const defaultTotal = 16;
  static const defaultExtended = 14;
  /// Focus + directs + extended on the canvas.
  static const defaultCanvasMax = 30;

  /// Direct neighbors to generate around a focus.
  final int total;
  /// Neighbors-of-neighbors to show (top-up after directs, within [canvasMax]).
  final int extended;
  final int canvasMax;

  factory NeighborhoodPrefs.fromJson(Map<String, dynamic>? _) {
    // API may still echo sizes; always use globals.
    return const NeighborhoodPrefs();
  }

  Map<String, int> toJson() => {
        'total': total,
        'extended': extended,
        'canvas_max': canvasMax,
      };
}

class TopicBit {
  const TopicBit({
    required this.id,
    required this.kind,
    required this.body,
    this.packIndex = 1,
    this.band = 'default',
    this.recipeVersion = 1,
    this.position = 0,
  });

  final String id;
  final String kind;
  final int packIndex;
  final String band;
  final int recipeVersion;
  final int position;
  final Map<String, dynamic> body;

  factory TopicBit.fromJson(Map<String, dynamic> raw) {
    final body = raw['body'];
    return TopicBit(
      id: raw['id']?.toString() ?? '',
      kind: raw['kind']?.toString() ?? '',
      packIndex: (raw['pack_index'] as num?)?.toInt() ?? 1,
      band: raw['band']?.toString() ?? 'default',
      recipeVersion: (raw['recipe_version'] as num?)?.toInt() ?? 1,
      position: (raw['position'] as num?)?.toInt() ?? 0,
      body: body is Map ? Map<String, dynamic>.from(body) : const {},
    );
  }
}

class TopicPack {
  const TopicPack({
    required this.packIndex,
    required this.incomplete,
    required this.bits,
    this.title,
    this.imageUrl,
    this.imageThumbUrl,
    this.packImageUrl,
    this.packImageThumbUrl,
  });

  final int packIndex;
  final bool incomplete;
  final String? title;
  final List<TopicBit> bits;
  /// Effective card image (pack override else topic).
  final String? imageUrl;
  final String? imageThumbUrl;
  /// Pack-only image when present (for Replace / Regenerate labels).
  final String? packImageUrl;
  final String? packImageThumbUrl;

  bool get hasPackImage {
    final url = packImageUrl?.trim();
    final thumb = packImageThumbUrl?.trim();
    return (url != null && url.isNotEmpty) || (thumb != null && thumb.isNotEmpty);
  }

  String? get bestImageUrl {
    final thumb = imageThumbUrl?.trim();
    if (thumb != null && thumb.isNotEmpty) return thumb;
    final full = imageUrl?.trim();
    if (full != null && full.isNotEmpty) return full;
    return null;
  }

  String get badgeLabel {
    final raw = title?.trim();
    final short = (raw == null || raw.isEmpty)
        ? 'Atom $packIndex'
        : (raw.length <= 28 ? raw : '${raw.substring(0, 27)}…');
    return '$packIndex · $short';
  }

  TopicBit? bit(String kind) {
    for (final bit in bits) {
      if (bit.kind == kind) return bit;
    }
    if (kind == 'check1') {
      for (final bit in bits) {
        if (bit.kind == 'check') return bit;
      }
    }
    return null;
  }

  TopicPack copyWith({
    String? imageUrl,
    String? imageThumbUrl,
    String? packImageUrl,
    String? packImageThumbUrl,
  }) {
    return TopicPack(
      packIndex: packIndex,
      incomplete: incomplete,
      title: title,
      bits: bits,
      imageUrl: imageUrl ?? this.imageUrl,
      imageThumbUrl: imageThumbUrl ?? this.imageThumbUrl,
      packImageUrl: packImageUrl ?? this.packImageUrl,
      packImageThumbUrl: packImageThumbUrl ?? this.packImageThumbUrl,
    );
  }

  factory TopicPack.fromJson(Map<String, dynamic> raw) {
    final rows = raw['bits'];
    return TopicPack(
      packIndex: (raw['pack_index'] as num?)?.toInt() ?? 1,
      incomplete: raw['incomplete'] == true,
      title: raw['title']?.toString(),
      imageUrl: raw['image_url']?.toString(),
      imageThumbUrl: raw['image_thumb_url']?.toString(),
      packImageUrl: raw['pack_image_url']?.toString(),
      packImageThumbUrl: raw['pack_image_thumb_url']?.toString(),
      bits: [
        if (rows is List)
          for (final row in rows)
            if (row is Map) TopicBit.fromJson(Map<String, dynamic>.from(row)),
      ],
    );
  }
}

class TopicContent {
  const TopicContent({
    required this.nodeId,
    required this.incomplete,
    required this.packs,
    this.band = 'default',
    this.recipeVersion = 1,
    this.packCount = 0,
    this.completedPacks = const [],
  });

  final String nodeId;
  final bool incomplete;
  final String band;
  final int recipeVersion;
  final int packCount;
  final List<TopicPack> packs;
  /// Pack indexes the current user has atomically walked (learn + any one check).
  final List<int> completedPacks;

  bool get allPacksComplete =>
      packs.isNotEmpty && packs.every((pack) => !pack.incomplete);

  bool isPackCompleted(int packIndex) => completedPacks.contains(packIndex);

  /// First pack the user has not finished yet; if none, the last pack.
  int initialPackIndex({Set<int> extraCompleted = const {}}) {
    if (packs.isEmpty) return 1;
    final done = {...completedPacks, ...extraCompleted};
    for (final pack in packs) {
      if (!done.contains(pack.packIndex)) return pack.packIndex;
    }
    return packs.last.packIndex;
  }

  TopicPack? pack(int packIndex) {
    for (final pack in packs) {
      if (pack.packIndex == packIndex) return pack;
    }
    return null;
  }

  factory TopicContent.fromJson(Map<String, dynamic> raw) {
    final packRows = raw['packs'];
    final packs = <TopicPack>[
      if (packRows is List)
        for (final row in packRows)
          if (row is Map) TopicPack.fromJson(Map<String, dynamic>.from(row)),
    ];
    // Legacy flat `bits` payload → single pack.
    if (packs.isEmpty) {
      final rows = raw['bits'];
      if (rows is List && rows.isNotEmpty) {
        final bits = [
          for (final row in rows)
            if (row is Map) TopicBit.fromJson(Map<String, dynamic>.from(row)),
        ];
        String? title;
        for (final bit in bits) {
          if (bit.kind != 'learn') continue;
          final value = bit.body['title']?.toString().trim();
          if (value != null && value.isNotEmpty) {
            title = value;
            break;
          }
        }
        packs.add(
          TopicPack(
            packIndex: 1,
            incomplete: raw['incomplete'] == true,
            title: title,
            bits: bits,
          ),
        );
      }
    }
    final completedRaw = raw['completed_packs'];
    return TopicContent(
      nodeId: raw['node_id']?.toString() ?? '',
      incomplete: raw['incomplete'] == true,
      band: raw['band']?.toString() ?? 'default',
      recipeVersion: (raw['recipe_version'] as num?)?.toInt() ?? 1,
      packCount: (raw['pack_count'] as num?)?.toInt() ?? packs.length,
      packs: packs,
      completedPacks: [
        if (completedRaw is List)
          for (final row in completedRaw)
            if (row is num) row.toInt(),
      ],
    );
  }
}

class LearningNext {
  const LearningNext({
    required this.status,
    required this.nodeId,
    required this.title,
    this.packIndex,
    this.pack,
    this.affinity = 0,
    this.completedPacks = const [],
    this.imageUrl,
    this.imageThumbUrl,
    this.packImageUrl,
    this.packImageThumbUrl,
  });

  /// `ready` or `generate`.
  final String status;
  final String nodeId;
  final String title;
  final int? packIndex;
  final TopicPack? pack;
  final double affinity;
  final List<int> completedPacks;
  final String? imageUrl;
  final String? imageThumbUrl;
  final String? packImageUrl;
  final String? packImageThumbUrl;

  bool get needsGenerate => status == 'generate';
  bool get isReady => status == 'ready' && pack != null;

  bool get hasPackImage {
    final url = packImageUrl?.trim();
    final thumb = packImageThumbUrl?.trim();
    return (url != null && url.isNotEmpty) || (thumb != null && thumb.isNotEmpty);
  }

  String? get bestImageUrl {
    final thumb = imageThumbUrl?.trim();
    if (thumb != null && thumb.isNotEmpty) return thumb;
    final full = imageUrl?.trim();
    if (full != null && full.isNotEmpty) return full;
    return null;
  }

  factory LearningNext.fromJson(Map<String, dynamic> raw) {
    final packRaw = raw['pack'];
    final completedRaw = raw['completed_packs'];
    return LearningNext(
      status: raw['status']?.toString() ?? 'generate',
      nodeId: raw['node_id']?.toString() ?? '',
      title: raw['title']?.toString() ?? '',
      packIndex: (raw['pack_index'] as num?)?.toInt(),
      pack: packRaw is Map ? TopicPack.fromJson(Map<String, dynamic>.from(packRaw)) : null,
      affinity: (raw['affinity'] as num?)?.toDouble() ?? 0,
      completedPacks: [
        if (completedRaw is List)
          for (final row in completedRaw)
            if (row is num) row.toInt(),
      ],
      imageUrl: raw['image_url']?.toString(),
      imageThumbUrl: raw['image_thumb_url']?.toString(),
      packImageUrl: raw['pack_image_url']?.toString(),
      packImageThumbUrl: raw['pack_image_thumb_url']?.toString(),
    );
  }
}

class LeitnerBinData {
  const LeitnerBinData({
    required this.bin,
    required this.count,
    required this.countDue,
    required this.countNotDue,
  });

  final int bin;
  final int count;
  final int countDue;
  final int countNotDue;

  factory LeitnerBinData.fromJson(Map<String, dynamic> raw) {
    return LeitnerBinData(
      bin: (raw['bin'] as num?)?.toInt() ?? 0,
      count: (raw['count'] as num?)?.toInt() ?? 0,
      countDue: (raw['count_due'] as num?)?.toInt() ?? 0,
      countNotDue: (raw['count_not_due'] as num?)?.toInt() ?? 0,
    );
  }
}

class LeitnerDistribution {
  const LeitnerDistribution({
    required this.graduationBin,
    required this.dueCount,
    required this.bins,
    this.firstNextReviewAt,
    this.intervalsHours = const [],
  });

  final int graduationBin;
  final int dueCount;
  final String? firstNextReviewAt;
  final List<int> intervalsHours;
  final List<LeitnerBinData> bins;

  factory LeitnerDistribution.fromJson(Map<String, dynamic> raw) {
    final rows = raw['distribution'];
    final intervals = raw['intervals_hours'];
    return LeitnerDistribution(
      graduationBin: (raw['graduation_bin'] as num?)?.toInt() ?? 7,
      dueCount: (raw['due_count'] as num?)?.toInt() ?? 0,
      firstNextReviewAt: raw['first_next_review_at']?.toString(),
      intervalsHours: [
        if (intervals is List)
          for (final row in intervals)
            if (row is num) row.toInt(),
      ],
      bins: [
        if (rows is List)
          for (final row in rows)
            if (row is Map) LeitnerBinData.fromJson(Map<String, dynamic>.from(row)),
      ],
    );
  }
}

class ReviewDueItem {
  const ReviewDueItem({
    required this.nodeId,
    required this.title,
    required this.packIndex,
    required this.leitnerBin,
    required this.pack,
    this.nextReviewAt,
    this.imageUrl,
    this.imageThumbUrl,
    this.packImageUrl,
    this.packImageThumbUrl,
  });

  final String nodeId;
  final String title;
  final int packIndex;
  final int leitnerBin;
  final TopicPack pack;
  final String? nextReviewAt;
  final String? imageUrl;
  final String? imageThumbUrl;
  final String? packImageUrl;
  final String? packImageThumbUrl;

  bool get hasPackImage {
    final url = packImageUrl?.trim();
    final thumb = packImageThumbUrl?.trim();
    return (url != null && url.isNotEmpty) || (thumb != null && thumb.isNotEmpty);
  }

  factory ReviewDueItem.fromJson(Map<String, dynamic> raw) {
    final packRaw = raw['pack'];
    return ReviewDueItem(
      nodeId: raw['node_id']?.toString() ?? '',
      title: raw['title']?.toString() ?? '',
      packIndex: (raw['pack_index'] as num?)?.toInt() ?? 1,
      leitnerBin: (raw['leitner_bin'] as num?)?.toInt() ?? 1,
      nextReviewAt: raw['next_review_at']?.toString(),
      imageUrl: raw['image_url']?.toString(),
      imageThumbUrl: raw['image_thumb_url']?.toString(),
      packImageUrl: raw['pack_image_url']?.toString(),
      packImageThumbUrl: raw['pack_image_thumb_url']?.toString(),
      pack: packRaw is Map
          ? TopicPack.fromJson(Map<String, dynamic>.from(packRaw))
          : const TopicPack(packIndex: 1, incomplete: true, bits: []),
    );
  }
}

class ReviewDueQueue {
  const ReviewDueQueue({required this.items, required this.dueCount});

  final List<ReviewDueItem> items;
  final int dueCount;

  factory ReviewDueQueue.fromJson(Map<String, dynamic> raw) {
    final rows = raw['items'];
    return ReviewDueQueue(
      dueCount: (raw['due_count'] as num?)?.toInt() ?? 0,
      items: [
        if (rows is List)
          for (final row in rows)
            if (row is Map) ReviewDueItem.fromJson(Map<String, dynamic>.from(row)),
      ],
    );
  }
}

class ReviewSubmitResult {
  const ReviewSubmitResult({
    required this.nodeId,
    required this.packIndex,
    required this.leitnerBin,
    required this.graduated,
    required this.updated,
    this.nextReviewAt,
    this.intervalHours,
  });

  final String nodeId;
  final int packIndex;
  final int leitnerBin;
  final bool graduated;
  final bool updated;
  final String? nextReviewAt;
  final int? intervalHours;

  factory ReviewSubmitResult.fromJson(Map<String, dynamic> raw) {
    return ReviewSubmitResult(
      nodeId: raw['node_id']?.toString() ?? '',
      packIndex: (raw['pack_index'] as num?)?.toInt() ?? 1,
      leitnerBin: (raw['leitner_bin'] as num?)?.toInt() ?? 1,
      graduated: raw['graduated'] == true,
      updated: raw['updated'] == true,
      nextReviewAt: raw['next_review_at']?.toString(),
      intervalHours: (raw['interval_hours'] as num?)?.toInt(),
    );
  }
}

class TrackedJob {
  const TrackedJob({
    required this.jobId,
    required this.nodeId,
    required this.title,
    required this.state,
    this.type = 'expand_neighborhood',
    this.packIndex,
    this.progressMessage,
    this.fraction = 0,
    this.errorMessage,
  });

  final String jobId;
  final String nodeId;
  final String title;
  final String state;
  final String type;
  final int? packIndex;
  final String? progressMessage;
  final double fraction;
  final String? errorMessage;

  bool get isActive => state == 'queued' || state == 'running';

  TrackedJob copyWith({
    String? state,
    String? progressMessage,
    double? fraction,
    String? errorMessage,
    String? title,
    String? type,
    int? packIndex,
  }) {
    return TrackedJob(
      jobId: jobId,
      nodeId: nodeId,
      title: title ?? this.title,
      state: state ?? this.state,
      type: type ?? this.type,
      packIndex: packIndex ?? this.packIndex,
      progressMessage: progressMessage ?? this.progressMessage,
      fraction: fraction ?? this.fraction,
      errorMessage: errorMessage,
    );
  }
}
