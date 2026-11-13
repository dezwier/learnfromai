import 'dart:async';

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
    this.extended = 12,
  });

  final int parents;
  final int siblings;
  final int children;
  final int acquaintances;
  /// How many neighbors-of-neighbors to show around the focus (0–24).
  final int extended;

  factory NeighborhoodPrefs.fromJson(Map<String, dynamic>? raw) {
    if (raw == null) return const NeighborhoodPrefs();
    return NeighborhoodPrefs(
      parents: (raw['parents'] as num?)?.toInt() ?? 2,
      siblings: (raw['siblings'] as num?)?.toInt() ?? 3,
      children: (raw['children'] as num?)?.toInt() ?? 4,
      acquaintances: (raw['acquaintances'] as num?)?.toInt() ?? 4,
      extended: (raw['extended'] as num?)?.toInt() ?? 12,
    );
  }

  Map<String, int> toJson() => {
        'parents': parents,
        'siblings': siblings,
        'children': children,
        'acquaintances': acquaintances,
        'extended': extended,
      };

  NeighborhoodPrefs copyWith({
    int? parents,
    int? siblings,
    int? children,
    int? acquaintances,
    int? extended,
  }) {
    return NeighborhoodPrefs(
      parents: parents ?? this.parents,
      siblings: siblings ?? this.siblings,
      children: children ?? this.children,
      acquaintances: acquaintances ?? this.acquaintances,
      extended: extended ?? this.extended,
    );
  }
}

class TrackedJob {
  const TrackedJob({
    required this.jobId,
    required this.nodeId,
    required this.title,
    required this.state,
    this.progressMessage,
    this.fraction = 0,
    this.errorMessage,
  });

  final String jobId;
  final String nodeId;
  final String title;
  final String state;
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
  }) {
    return TrackedJob(
      jobId: jobId,
      nodeId: nodeId,
      title: title ?? this.title,
      state: state ?? this.state,
      progressMessage: progressMessage ?? this.progressMessage,
      fraction: fraction ?? this.fraction,
      errorMessage: errorMessage,
    );
  }
}

class GraphController extends ChangeNotifier {
  GraphController({
    this.api,
    this.loader,
    this.poster,
    this.patcher,
    this.deleter,
    this.jobLoader,
  });

  final ApiClient? api;
  final Future<Map<String, dynamic>> Function(String path)? loader;
  final Future<Map<String, dynamic>> Function(String path, {Object? body})? poster;
  final Future<Map<String, dynamic>> Function(String path, {Object? body})? patcher;
  final Future<Map<String, dynamic>> Function(String path)? deleter;
  final Future<Map<String, dynamic>> Function(String jobId)? jobLoader;

  Map<String, dynamic>? categoryGraph;
  bool loading = false;
  bool refreshing = false;
  String? error;
  List<TopicChoice> candidates = [];
  List<TopicChoice> suggestions = [];
  final List<String> focusHistory = [];
  NeighborhoodPrefs prefs = const NeighborhoodPrefs();
  final List<TrackedJob> trackedJobs = [];
  int _suggestToken = 0;
  Timer? _jobPoller;
  var _polling = false;
  var _disposed = false;

  String? get focusId {
    final raw = categoryGraph?['focus_node_id'];
    if (raw == null) return null;
    return raw.toString();
  }

  bool get canGoBack => focusHistory.length > 1 && !refreshing;

  int get activeJobCount => trackedJobs.where((j) => j.isActive).length;

  bool get hasActiveJobs => activeJobCount > 0;

  /// True while any neighborhood expand is in flight (badge / drawer), not a nav lock.
  bool get working => hasActiveJobs;

  String? get progressMessage {
    final focus = focusId;
    if (focus != null) {
      final forFocus = jobForNode(focus);
      if (forFocus != null) return forFocus.progressMessage;
    }
    if (trackedJobs.isEmpty) return null;
    return trackedJobs.first.progressMessage;
  }

  String? get pendingNodeId {
    final focus = focusId;
    if (focus != null && jobForNode(focus) != null) return focus;
    return trackedJobs.isEmpty ? null : trackedJobs.first.nodeId;
  }

  TrackedJob? jobForNode(String nodeId) {
    for (final job in trackedJobs) {
      if (job.nodeId == nodeId && job.isActive) return job;
    }
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    _jobPoller?.cancel();
    _jobPoller = null;
    super.dispose();
  }

  Future<void> resume() async {
    if (categoryGraph != null || candidates.isNotEmpty || loading || refreshing) return;
    await loadPreferences();
    await _focus(body: const {});
    unawaited(refreshTrackedJobs());
  }

  Future<void> search(String topic) async {
    final trimmed = topic.trim();
    if (trimmed.isEmpty || refreshing || loading) return;
    suggestions = [];
    final previous = List<String>.of(focusHistory);
    focusHistory.clear();
    await _focus(body: {'topic': trimmed});
    if (error != null || candidates.isNotEmpty) {
      focusHistory
        ..clear()
        ..addAll(previous);
    }
  }

  Future<void> suggest(String query) async {
    final trimmed = query.trim();
    final token = ++_suggestToken;
    if (trimmed.isEmpty) {
      if (suggestions.isEmpty) return;
      suggestions = [];
      notifyListeners();
      return;
    }
    try {
      final raw = await _get('/knowledge/nodes?q=${Uri.encodeQueryComponent(trimmed)}');
      if (token != _suggestToken) return;
      suggestions = _choices({'candidates': raw['nodes']});
      notifyListeners();
    } on ApiException {
      if (token != _suggestToken) return;
      suggestions = [];
      notifyListeners();
    }
  }

  void clearSuggestions() {
    _suggestToken += 1;
    if (suggestions.isEmpty) return;
    suggestions = [];
    notifyListeners();
  }

  Future<void> openNode(String id) async {
    if (refreshing || loading) return;
    if (focusId == id && categoryGraph != null) return;
    await _focus(body: {'node_id': id});
  }

  /// Open an existing node via GET graph, then enqueue expand without blocking.
  Future<void> openExisting(String id, {String? title}) async {
    if (refreshing || loading) return;
    if (focusId == id && categoryGraph != null && categoryGraph?['incomplete'] != true) {
      suggestions = [];
      notifyListeners();
      return;
    }
    if (focusId == id && categoryGraph != null) {
      suggestions = [];
      notifyListeners();
      unawaited(enqueueNeighborhood(id, title: title));
      return;
    }
    final first = categoryGraph == null;
    loading = first;
    refreshing = !first;
    error = null;
    candidates = [];
    suggestions = [];
    notifyListeners();
    var openedId = id;
    try {
      categoryGraph = await _get('/knowledge/graph/$id');
      openedId = focusId ?? id;
      if (focusHistory.isEmpty || focusHistory.last != openedId) {
        focusHistory.add(openedId);
      }
    } on ApiException catch (exc) {
      error = exc.message;
    } finally {
      loading = false;
      refreshing = false;
      notifyListeners();
    }
    if (error == null && categoryGraph?['incomplete'] == true) {
      unawaited(enqueueNeighborhood(openedId, title: title));
    }
  }

  /// POST focus. If the neighborhood is complete, switch focus to [id].
  /// If incomplete, enqueue the expand and keep the current graph.
  /// Returns true when focus switched.
  Future<bool> openIfCompleteOrEnqueue(String id, {String? title}) async {
    if (focusId == id && categoryGraph != null && categoryGraph?['incomplete'] != true) {
      return false;
    }
    if (jobForNode(id) != null) {
      _ensurePoller();
      return false;
    }
    try {
      final payload = await _post('/knowledge/focus', body: {'node_id': id});
      final jobId = payload['job_id']?.toString();
      if (jobId != null) {
        _trackJobFromPayload(payload, id: id, title: title);
        return false;
      }
      // Neighbors are complete — change to that tile.
      if (payload['nodes'] is List) {
        categoryGraph = payload;
      } else {
        categoryGraph = await _get('/knowledge/graph/$id');
      }
      final openedId = focusId ?? id;
      if (focusHistory.isEmpty || focusHistory.last != openedId) {
        focusHistory.add(openedId);
      }
      suggestions = [];
      notifyListeners();
      return true;
    } on ApiException catch (exc) {
      if (exc.status == 409) {
        candidates = _choices(exc.details);
        notifyListeners();
      } else {
        error = exc.message;
        notifyListeners();
      }
      return false;
    }
  }

  /// POST focus; if a job is returned, track it without awaiting completion.
  Future<void> enqueueNeighborhood(String id, {String? title}) async {
    if (jobForNode(id) != null) {
      _ensurePoller();
      return;
    }
    try {
      final payload = await _post('/knowledge/focus', body: {'node_id': id});
      final jobId = payload['job_id']?.toString();
      if (jobId == null) {
        // Already complete — refresh graph if we're still on this focus.
        if (focusId == id || focusId == payload['focus_node_id']?.toString()) {
          if (payload['nodes'] is List) {
            categoryGraph = payload;
          } else {
            categoryGraph = await _get('/knowledge/graph/$id');
          }
          notifyListeners();
        }
        return;
      }
      _trackJobFromPayload(payload, id: id, title: title);
    } on ApiException catch (exc) {
      if (exc.status == 409) {
        candidates = _choices(exc.details);
        notifyListeners();
      } else {
        error = exc.message;
        notifyListeners();
      }
    }
  }

  void _trackJobFromPayload(Map<String, dynamic> payload, {required String id, String? title}) {
    final jobId = payload['job_id']?.toString();
    if (jobId == null) return;
    final focusNodeId = payload['focus_node_id']?.toString() ?? id;
    final progress = payload['progress'];
    final message = progress is Map ? progress['message']?.toString() : null;
    final fraction = progress is Map ? (progress['fraction'] as num?)?.toDouble() ?? 0 : 0.0;
    _upsertTracked(
      TrackedJob(
        jobId: jobId,
        nodeId: focusNodeId,
        title: title ?? _titleForNode(focusNodeId) ?? 'Topic',
        state: 'queued',
        progressMessage: message ?? 'Waiting for a worker…',
        fraction: fraction,
      ),
    );
    _ensurePoller();
  }

  Future<void> choose(TopicChoice choice) async {
    candidates = [];
    notifyListeners();
    await openExisting(choice.id, title: choice.title);
  }

  Future<void> back() async {
    if (!canGoBack) return;
    final current = focusHistory.removeLast();
    final previous = focusHistory.last;
    await openExisting(previous);
    if (error != null) focusHistory.add(current);
  }

  Future<bool> updateNode({
    required String id,
    String? title,
    String? description,
  }) async {
    if (refreshing || loading) return false;
    error = null;
    notifyListeners();
    try {
      final body = <String, dynamic>{};
      if (title != null) body['name'] = title;
      if (description != null) body['description'] = description;
      final updated = await _patch('/knowledge/nodes/$id', body: body);
      _patchLocalNode(
        id,
        title: updated['title']?.toString() ?? title,
        description: updated.containsKey('description')
            ? updated['description']?.toString()
            : description,
      );
      notifyListeners();
      return true;
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
      return false;
    }
  }

  Future<bool> deleteNode(String id) async {
    if (refreshing || loading) return false;
    final wasFocus = focusId == id;
    error = null;
    notifyListeners();
    try {
      await _delete('/knowledge/nodes/$id');
      focusHistory.removeWhere((entry) => entry == id);
      trackedJobs.removeWhere((j) => j.nodeId == id);
      if (wasFocus) {
        if (focusHistory.isNotEmpty) {
          await openExisting(focusHistory.last);
        } else {
          categoryGraph = null;
          notifyListeners();
        }
      } else {
        final focus = focusId;
        if (focus != null) {
          await openExisting(focus);
        }
      }
      return true;
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
      return false;
    }
  }

  void _patchLocalNode(String id, {String? title, String? description}) {
    final payload = categoryGraph;
    if (payload == null) return;
    final nodes = payload['nodes'];
    if (nodes is! List) return;
    for (var i = 0; i < nodes.length; i++) {
      final raw = nodes[i];
      if (raw is! Map || raw['id']?.toString() != id) continue;
      final next = Map<String, dynamic>.from(raw);
      if (title != null) next['title'] = title;
      if (description != null) next['description'] = description;
      nodes[i] = next;
      break;
    }
    categoryGraph = Map<String, dynamic>.from(payload)..['nodes'] = nodes;
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
      final id = focusId;
      if (id != null && !refreshing && !loading) {
        await openExisting(id);
      }
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
    }
  }

  Future<void> refreshTrackedJobs() async {
    try {
      final raw = await _get('/jobs?state=queued,running');
      final list = raw['jobs'];
      if (list is! List) return;
      final next = <TrackedJob>[];
      for (final item in list) {
        if (item is! Map) continue;
        final jobId = item['id']?.toString();
        final nodeId = item['focus_node_id']?.toString();
        if (jobId == null || nodeId == null) continue;
        final progress = item['progress'];
        next.add(
          TrackedJob(
            jobId: jobId,
            nodeId: nodeId,
            title: item['title']?.toString() ?? 'Topic',
            state: item['state']?.toString() ?? 'queued',
            progressMessage: progress is Map ? progress['message']?.toString() : null,
            fraction: progress is Map ? (progress['fraction'] as num?)?.toDouble() ?? 0 : 0,
          ),
        );
      }
      trackedJobs
        ..clear()
        ..addAll(next);
      notifyListeners();
      if (trackedJobs.isNotEmpty) _ensurePoller();
    } on ApiException {
      // Ignore list failures; individual polls still work.
    }
  }

  Future<void> _focus({required Map<String, dynamic> body, bool record = true}) async {
    final first = categoryGraph == null;
    loading = first;
    refreshing = !first;
    error = null;
    candidates = [];
    notifyListeners();
    try {
      final payload = await _post('/knowledge/focus', body: body);
      final focus = payload['focus_node_id']?.toString() ?? body['node_id']?.toString();
      if (payload['job_id'] != null) {
        if (focus != null) {
          try {
            categoryGraph = await _get('/knowledge/graph/$focus');
          } on ApiException {
            // Keep prior graph if GET fails while job is queued.
          }
        }
        final progress = payload['progress'];
        _upsertTracked(
          TrackedJob(
            jobId: payload['job_id'].toString(),
            nodeId: focus ?? payload['job_id'].toString(),
            title: body['topic']?.toString() ?? _titleForNode(focus ?? '') ?? 'Topic',
            state: 'queued',
            progressMessage:
                progress is Map ? progress['message']?.toString() : 'Waiting for a worker…',
            fraction: progress is Map ? (progress['fraction'] as num?)?.toDouble() ?? 0 : 0,
          ),
        );
        _ensurePoller();
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
      notifyListeners();
    }
  }

  void _upsertTracked(TrackedJob job) {
    final index = trackedJobs.indexWhere((j) => j.jobId == job.jobId || j.nodeId == job.nodeId);
    if (index >= 0) {
      trackedJobs[index] = job;
    } else {
      trackedJobs.insert(0, job);
    }
    notifyListeners();
  }

  void _ensurePoller() {
    if (_jobPoller != null) return;
    _jobPoller = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_pollTrackedJobs());
    });
    unawaited(_pollTrackedJobs());
  }

  Future<void> _pollTrackedJobs() async {
    if (_polling || _disposed) return;
    if (trackedJobs.isEmpty) {
      _jobPoller?.cancel();
      _jobPoller = null;
      return;
    }
    _polling = true;
    try {
      final snapshot = List<TrackedJob>.of(trackedJobs);
      for (final tracked in snapshot) {
        if (!tracked.isActive) continue;
        try {
          final job = await _job(tracked.jobId);
          if (_disposed) return;
          final state = job['state']?.toString() ?? tracked.state;
          final progress = job['progress'];
          final message = progress is Map ? progress['message']?.toString() : tracked.progressMessage;
          final fraction =
              progress is Map ? (progress['fraction'] as num?)?.toDouble() ?? tracked.fraction : tracked.fraction;
          if (state == 'succeeded') {
            trackedJobs.removeWhere((j) => j.jobId == tracked.jobId);
            final result = job['result'];
            final resultFocus = result is Map ? result['focus_id']?.toString() : null;
            final loadId = resultFocus ?? tracked.nodeId;
            // Soft-refresh the current view so neighbor expands appear without jumping focus.
            final refreshId =
                (focusId == tracked.nodeId || focusId == loadId) ? loadId : focusId;
            if (refreshId != null) {
              try {
                categoryGraph = await _get('/knowledge/graph/$refreshId');
              } on ApiException {
                // Keep current graph.
              }
            }
            notifyListeners();
            continue;
          }
          if (state == 'failed') {
            trackedJobs.removeWhere((j) => j.jobId == tracked.jobId);
            // Surface briefly via error only if user is on that topic.
            if (focusId == tracked.nodeId) {
              error = job['error_message']?.toString() ?? 'Neighborhood generation failed';
            }
            notifyListeners();
            continue;
          }
          _upsertTracked(
            tracked.copyWith(
              state: state,
              progressMessage: message,
              fraction: fraction,
            ),
          );
        } on ApiException {
          // Keep tracking; next tick retries.
        }
      }
      if (trackedJobs.isEmpty) {
        _jobPoller?.cancel();
        _jobPoller = null;
      }
    } finally {
      _polling = false;
    }
  }

  String? _titleForNode(String id) {
    if (id.isEmpty) return null;
    final nodes = categoryGraph?['nodes'];
    if (nodes is! List) return null;
    for (final raw in nodes) {
      if (raw is Map && raw['id']?.toString() == id) {
        return raw['title']?.toString();
      }
    }
    return null;
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

  Future<Map<String, dynamic>> _delete(String path) async {
    final del = deleter;
    if (del != null) return Map<String, dynamic>.from(await del(path));
    final client = api;
    if (client == null) throw ApiException(0, 'NETWORK', 'API is not configured');
    final raw = await client.delete(path);
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return <String, dynamic>{};
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
