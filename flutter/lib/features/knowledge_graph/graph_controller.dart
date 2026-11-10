import 'package:flutter/foundation.dart';

import '../../core/networking/api_client.dart';
import '../../core/networking/api_exception.dart';

class TopicChoice {
  const TopicChoice({required this.id, required this.title, this.description});

  final String id;
  final String title;
  final String? description;
}

class NeighborhoodPrefs {
  const NeighborhoodPrefs({
    this.parents = 2,
    this.siblings = 3,
    this.children = 4,
    this.acquaintances = 4,
  });

  final int parents;
  final int siblings;
  final int children;
  final int acquaintances;

  factory NeighborhoodPrefs.fromJson(Map<String, dynamic>? raw) {
    if (raw == null) return const NeighborhoodPrefs();
    return NeighborhoodPrefs(
      parents: (raw['parents'] as num?)?.toInt() ?? 2,
      siblings: (raw['siblings'] as num?)?.toInt() ?? 3,
      children: (raw['children'] as num?)?.toInt() ?? 4,
      acquaintances: (raw['acquaintances'] as num?)?.toInt() ?? 4,
    );
  }

  Map<String, int> toJson() => {
        'parents': parents,
        'siblings': siblings,
        'children': children,
        'acquaintances': acquaintances,
      };

  NeighborhoodPrefs copyWith({int? parents, int? siblings, int? children, int? acquaintances}) {
    return NeighborhoodPrefs(
      parents: parents ?? this.parents,
      siblings: siblings ?? this.siblings,
      children: children ?? this.children,
      acquaintances: acquaintances ?? this.acquaintances,
    );
  }
}

class GraphController extends ChangeNotifier {
  GraphController({this.api, this.loader, this.poster, this.patcher, this.jobLoader});

  final ApiClient? api;
  final Future<Map<String, dynamic>> Function(String path)? loader;
  final Future<Map<String, dynamic>> Function(String path, {Object? body})? poster;
  final Future<Map<String, dynamic>> Function(String path, {Object? body})? patcher;
  final Future<Map<String, dynamic>> Function(String jobId)? jobLoader;

  Map<String, dynamic>? categoryGraph;
  bool loading = false;
  bool refreshing = false;
  bool working = false;
  String? pendingNodeId;
  String? error;
  String? progressMessage;
  List<TopicChoice> candidates = [];
  final List<String> focusHistory = [];
  NeighborhoodPrefs prefs = const NeighborhoodPrefs();

  String? get focusId {
    final raw = categoryGraph?['focus_node_id'];
    if (raw == null) return null;
    return raw.toString();
  }

  bool get canGoBack => focusHistory.length > 1 && !refreshing && !working;

  Future<void> resume() async {
    if (categoryGraph != null || candidates.isNotEmpty || loading || refreshing || working) return;
    await loadPreferences();
    await _focus(body: const {});
  }

  Future<void> search(String topic) async {
    final trimmed = topic.trim();
    if (trimmed.isEmpty || refreshing || loading || working) return;
    final previous = List<String>.of(focusHistory);
    focusHistory.clear();
    await _focus(body: {'topic': trimmed});
    if (error != null || candidates.isNotEmpty) {
      focusHistory
        ..clear()
        ..addAll(previous);
    }
  }

  Future<void> openNode(String id) async {
    if (refreshing || loading || working) return;
    if (focusId == id && categoryGraph != null) return;
    pendingNodeId = id;
    await _focus(body: {'node_id': id});
  }

  Future<void> choose(TopicChoice choice) async {
    candidates = [];
    notifyListeners();
    await openNode(choice.id);
  }

  Future<void> back() async {
    if (!canGoBack) return;
    final current = focusHistory.removeLast();
    final previous = focusHistory.last;
    await _focus(body: {'node_id': previous}, record: false);
    if (error != null) focusHistory.add(current);
  }

  Future<void> loadPreferences() async {
    try {
      final raw = await _get('/me/preferences');
      final neighborhood = raw['neighborhood'];
      if (neighborhood is Map<String, dynamic>) {
        prefs = NeighborhoodPrefs.fromJson(neighborhood);
        notifyListeners();
      }
    } on ApiException {
      // Keep defaults when preferences are unavailable.
    }
  }

  Future<void> savePreferences(NeighborhoodPrefs next) async {
    prefs = next;
    notifyListeners();
    try {
      final raw = await _patch('/me/preferences', body: {'neighborhood': next.toJson()});
      final neighborhood = raw['neighborhood'];
      if (neighborhood is Map<String, dynamic>) {
        prefs = NeighborhoodPrefs.fromJson(neighborhood);
        notifyListeners();
      }
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
    }
  }

  Future<void> _focus({required Map<String, dynamic> body, bool record = true}) async {
    final first = categoryGraph == null;
    loading = first;
    refreshing = !first;
    error = null;
    candidates = [];
    progressMessage = null;
    notifyListeners();
    try {
      final payload = await _post('/knowledge/focus', body: body);
      if (payload['job_id'] != null) {
        await _waitForJob(payload['job_id'].toString());
        final focus = payload['focus_node_id']?.toString() ??
            (categoryGraph?['focus_node_id']?.toString()) ??
            body['node_id']?.toString();
        if (focus == null) {
          throw ApiException(500, 'JOB', 'Neighborhood job finished without a focus');
        }
        categoryGraph = await _get('/knowledge/graph/$focus');
      } else {
        categoryGraph = payload;
      }
      final id = focusId;
      if (record && id != null && (focusHistory.isEmpty || focusHistory.last != id)) {
        focusHistory.add(id);
      }
    } on ApiException catch (exc) {
      if (exc.status == 409) {
        candidates = _choices(exc.details);
      } else {
        error = exc.message;
      }
    } finally {
      loading = false;
      refreshing = false;
      working = false;
      pendingNodeId = null;
      progressMessage = null;
      notifyListeners();
    }
  }

  Future<void> _waitForJob(String jobId) async {
    working = true;
    progressMessage = 'Waiting for a worker…';
    notifyListeners();
    for (var attempt = 0; attempt < 180; attempt++) {
      final job = await _job(jobId);
      final progress = job['progress'];
      if (progress is Map && progress['message'] != null) {
        progressMessage = progress['message'].toString();
      }
      notifyListeners();
      final state = job['state']?.toString();
      if (state == 'succeeded') return;
      if (state == 'failed') {
        throw ApiException(
          500,
          job['error_code']?.toString() ?? 'JOB_FAILED',
          job['error_message']?.toString() ?? 'Neighborhood generation failed',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    throw ApiException(504, 'JOB_TIMEOUT', 'Neighborhood generation timed out');
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final fetch = loader;
    if (fetch != null) return Map<String, dynamic>.from(await fetch(path));
    final client = api;
    if (client == null) throw ApiException(0, 'NETWORK', 'API is not configured');
    return Map<String, dynamic>.from(await client.get(path) as Map);
  }

  Future<Map<String, dynamic>> _post(String path, {Object? body}) async {
    final post = poster;
    if (post != null) return Map<String, dynamic>.from(await post(path, body: body));
    final client = api;
    if (client == null) throw ApiException(0, 'NETWORK', 'API is not configured');
    return Map<String, dynamic>.from(await client.post(path, body: body) as Map);
  }

  Future<Map<String, dynamic>> _patch(String path, {Object? body}) async {
    final patch = patcher;
    if (patch != null) return Map<String, dynamic>.from(await patch(path, body: body));
    final client = api;
    if (client == null) throw ApiException(0, 'NETWORK', 'API is not configured');
    return Map<String, dynamic>.from(await client.patch(path, body: body) as Map);
  }

  Future<Map<String, dynamic>> _job(String jobId) async {
    final custom = jobLoader;
    if (custom != null) return Map<String, dynamic>.from(await custom(jobId));
    return _get('/jobs/$jobId');
  }

  List<TopicChoice> _choices(Map<String, dynamic> details) {
    final raw = details['candidates'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map)
          TopicChoice(
            id: (item['id'] ?? item['node_id'] ?? item['wikidata_qid']).toString(),
            title: item['title']?.toString() ?? item['name']?.toString() ?? 'Topic',
            description: item['description']?.toString(),
          ),
    ];
  }
}
