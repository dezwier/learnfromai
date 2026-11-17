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
    if (value == openai || value == 'gpt' || value == 'chatgpt') return openai;
    return gemini;
  }

  static String label(String provider) =>
      provider == openai ? 'ChatGPT' : 'Gemini';
}

class NeighborhoodPrefs {
  const NeighborhoodPrefs({
    this.total = 16,
    this.extended = 12,
  });

  /// Total direct neighbors to fetch; the model chooses parents/siblings/children/related.
  final int total;
  /// How many neighbors-of-neighbors to show around the focus (0–24).
  final int extended;

  factory NeighborhoodPrefs.fromJson(Map<String, dynamic>? raw) {
    if (raw == null) return const NeighborhoodPrefs();
    final total = (raw['total'] as num?)?.toInt();
    if (total != null) {
      return NeighborhoodPrefs(
        total: total.clamp(8, 32),
        extended: (raw['extended'] as num?)?.toInt() ?? 12,
      );
    }
    // Legacy per-bucket prefs → sum into a total budget.
    final legacy = (raw['parents'] as num?)?.toInt() ?? 0;
    final siblings = (raw['siblings'] as num?)?.toInt() ?? 0;
    final children = (raw['children'] as num?)?.toInt() ?? 0;
    final acquaintances = (raw['acquaintances'] as num?)?.toInt() ?? 0;
    final summed = legacy + siblings + children + acquaintances;
    return NeighborhoodPrefs(
      total: (summed > 0 ? summed : 16).clamp(8, 32),
      extended: (raw['extended'] as num?)?.toInt() ?? 12,
    );
  }

  Map<String, int> toJson() => {
        'total': total,
        'extended': extended,
      };

  NeighborhoodPrefs copyWith({
    int? total,
    int? extended,
  }) {
    return NeighborhoodPrefs(
      total: total ?? this.total,
      extended: extended ?? this.extended,
    );
  }
}

class TopicBit {
  const TopicBit({
    required this.id,
    required this.kind,
    required this.body,
    this.band = 'default',
    this.recipeVersion = 1,
    this.position = 0,
  });

  final String id;
  final String kind;
  final String band;
  final int recipeVersion;
  final int position;
  final Map<String, dynamic> body;

  factory TopicBit.fromJson(Map<String, dynamic> raw) {
    final body = raw['body'];
    return TopicBit(
      id: raw['id']?.toString() ?? '',
      kind: raw['kind']?.toString() ?? '',
      band: raw['band']?.toString() ?? 'default',
      recipeVersion: (raw['recipe_version'] as num?)?.toInt() ?? 1,
      position: (raw['position'] as num?)?.toInt() ?? 0,
      body: body is Map ? Map<String, dynamic>.from(body) : const {},
    );
  }
}

class TopicContent {
  const TopicContent({
    required this.nodeId,
    required this.incomplete,
    required this.bits,
    this.band = 'default',
    this.recipeVersion = 1,
  });

  final String nodeId;
  final bool incomplete;
  final String band;
  final int recipeVersion;
  final List<TopicBit> bits;

  TopicBit? bit(String kind) {
    for (final bit in bits) {
      if (bit.kind == kind) return bit;
    }
    // Legacy API rows used kind "check" for the first question.
    if (kind == 'check1') {
      for (final bit in bits) {
        if (bit.kind == 'check') return bit;
      }
    }
    return null;
  }

  factory TopicContent.fromJson(Map<String, dynamic> raw) {
    final rows = raw['bits'];
    return TopicContent(
      nodeId: raw['node_id']?.toString() ?? '',
      incomplete: raw['incomplete'] == true,
      band: raw['band']?.toString() ?? 'default',
      recipeVersion: (raw['recipe_version'] as num?)?.toInt() ?? 1,
      bits: [
        if (rows is List)
          for (final row in rows)
            if (row is Map) TopicBit.fromJson(Map<String, dynamic>.from(row)),
      ],
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
    this.progressMessage,
    this.fraction = 0,
    this.errorMessage,
  });

  final String jobId;
  final String nodeId;
  final String title;
  final String state;
  final String type;
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
  }) {
    return TrackedJob(
      jobId: jobId,
      nodeId: nodeId,
      title: title ?? this.title,
      state: state ?? this.state,
      type: type ?? this.type,
      progressMessage: progressMessage ?? this.progressMessage,
      fraction: fraction ?? this.fraction,
      errorMessage: errorMessage,
    );
  }
}
