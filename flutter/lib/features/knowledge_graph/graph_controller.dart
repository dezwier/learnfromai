import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../core/networking/api_client.dart';
import '../../core/networking/api_exception.dart';

class TopicChoice {
  const TopicChoice({required this.id, required this.title, this.description});

  final String id;
  final String title;
  final String? description;
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

class GraphController extends ChangeNotifier {
  GraphController({
    this.api,
    this.loader,
    this.poster,
    this.patcher,
    this.deleter,
    this.jobLoader,
    this.bytesLoader,
  });

  final ApiClient? api;
  final Future<Map<String, dynamic>> Function(String path)? loader;
  final Future<Map<String, dynamic>> Function(String path, {Object? body})? poster;
  final Future<Map<String, dynamic>> Function(String path, {Object? body})? patcher;
  final Future<Map<String, dynamic>> Function(String path)? deleter;
  final Future<Map<String, dynamic>> Function(String jobId)? jobLoader;
  final Future<List<int>> Function(String path)? bytesLoader;

  Map<String, dynamic>? categoryGraph;
  bool loading = false;
  bool refreshing = false;
  String? error;
  List<TopicChoice> candidates = [];
  List<TopicChoice> suggestions = [];
  final List<String> focusHistory = [];
  NeighborhoodPrefs prefs = const NeighborhoodPrefs();
  String llmProvider = LlmProviderPref.gemini;
  final List<TrackedJob> trackedJobs = [];
  /// Set when an expand job succeeds; UI consumes then [clearLastCompleted].
  String? lastCompletedNodeId;
  String? lastCompletedJobType;
  /// Auth-fetched image bytes keyed by API image path (full or thumb).
  final Map<String, Uint8List> imageBytesByUrl = {};
  final Set<String> _imageLoadsInFlight = {};
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

  /// True while any neighborhood expand is in flight (badge / topic UI), not a nav lock.
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
    await loadPreferences();
    if (categoryGraph == null && candidates.isEmpty && !loading && !refreshing) {
      await _focus(body: const {});
    }
    // Always re-hook watched jobs (cold start or after the OS suspended timers).
    await reattachJobs();
  }

  /// Pull active watched jobs from the server and restart polling.
  Future<void> reattachJobs() async {
    await refreshTrackedJobs();
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

  void clearLastCompleted() {
    lastCompletedNodeId = null;
    lastCompletedJobType = null;
  }

  /// GET neighborhood for [id] without changing the current focus graph.
  Future<Map<String, dynamic>?> fetchGraph(String id) async {
    try {
      return await _get('/knowledge/graph/$id');
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
      return null;
    }
  }

  /// Open an existing node via GET graph (no expand enqueue).
  Future<void> openExisting(String id, {String? title, Map<String, dynamic>? knownPayload}) async {
    if (refreshing || loading) return;
    if (focusId == id && categoryGraph != null && knownPayload == null) {
      suggestions = [];
      notifyListeners();
      return;
    }
    final first = categoryGraph == null;
    loading = first;
    refreshing = !first;
    error = null;
    candidates = [];
    suggestions = [];
    notifyListeners();
    try {
      if (knownPayload != null && knownPayload['nodes'] is List) {
        categoryGraph = knownPayload;
      } else {
        categoryGraph = await _get('/knowledge/graph/$id');
      }
      final openedId = focusId ?? id;
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
  }

  /// GET shared learn / example / check bits (never enqueues).
  Future<TopicContent?> fetchContent(String nodeId) async {
    try {
      final raw = await _get('/knowledge/nodes/$nodeId/content');
      return TopicContent.fromJson(raw);
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
      return null;
    }
  }

  /// Request shared content expand when incomplete; track the job like neighborhood.
  Future<TopicContent?> enqueueContent(String id, {String? title}) async {
    if (jobForNode(id) != null) {
      _ensurePoller();
      return fetchContent(id);
    }
    try {
      final payload = await _post('/knowledge/nodes/$id/content', body: {'expand': true});
      final jobId = payload['job_id']?.toString();
      if (jobId == null) {
        return TopicContent.fromJson(payload);
      }
      _trackJobFromPayload(payload, id: id, title: title, type: 'expand_content');
      return TopicContent(
        nodeId: payload['focus_node_id']?.toString() ?? id,
        incomplete: true,
        bits: const [],
      );
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
      return null;
    }
  }

  /// Request shared topic image generation (or regeneration when [regenerate] is true).
  Future<bool> enqueueImage(String id, {String? title, bool regenerate = false}) async {
    if (jobForNode(id) != null) {
      _ensurePoller();
      return true;
    }
    try {
      final body = regenerate ? {'regenerate': true} : {'generate': true};
      final payload = await _post('/knowledge/nodes/$id/image', body: body);
      final jobId = payload['job_id']?.toString();
      if (jobId == null) {
        final imageUrl = payload['image_url']?.toString();
        if (imageUrl != null && imageUrl.isNotEmpty) {
          patchNodeImageUrl(id, imageUrl);
        }
        return true;
      }
      _trackJobFromPayload(payload, id: id, title: title, type: 'generate_image');
      return true;
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
      return false;
    }
  }

  /// Authenticated image bytes for a topic image path from the graph payload.
  Future<List<int>?> fetchImageBytes(String imageUrl) async {
    final path = _apiPathFromImageUrl(imageUrl);
    if (path == null) return null;
    final cached = imageBytesByUrl[path] ?? imageBytesByUrl[imageUrl];
    if (cached != null) return cached;
    try {
      final bytes = await _getBytes(path);
      final stored = Uint8List.fromList(bytes);
      imageBytesByUrl[path] = stored;
      imageBytesByUrl[imageUrl] = stored;
      notifyListeners();
      return stored;
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
      return null;
    }
  }

  Uint8List? cachedImageBytes(String? imageUrl) {
    if (imageUrl == null || imageUrl.trim().isEmpty) return null;
    final path = _apiPathFromImageUrl(imageUrl) ?? imageUrl;
    return imageBytesByUrl[path] ?? imageBytesByUrl[imageUrl];
  }

  /// Fire-and-forget load for graph thumbs; notifies when bytes arrive.
  void ensureImageCached(String? imageUrl) {
    if (imageUrl == null || imageUrl.trim().isEmpty) return;
    if (cachedImageBytes(imageUrl) != null) return;
    final path = _apiPathFromImageUrl(imageUrl) ?? imageUrl;
    if (!_imageLoadsInFlight.add(path)) return;
    unawaited(() async {
      try {
        await fetchImageBytes(imageUrl);
      } finally {
        _imageLoadsInFlight.remove(path);
      }
    }());
  }

  void preloadGraphImages() {
    final nodes = categoryGraph?['nodes'];
    if (nodes is! List) return;
    for (final raw in nodes) {
      if (raw is! Map) continue;
      final thumb = raw['image_thumb_url']?.toString();
      final full = raw['image_url']?.toString();
      ensureImageCached((thumb != null && thumb.isNotEmpty) ? thumb : full);
    }
  }

  void patchNodeImageUrl(String nodeId, String? imageUrl, {String? imageThumbUrl}) {
    final graph = categoryGraph;
    if (graph == null) return;
    final nodes = graph['nodes'];
    if (nodes is! List) return;
    var changed = false;
    final next = <dynamic>[];
    for (final raw in nodes) {
      if (raw is Map && raw['id']?.toString() == nodeId) {
        final copy = Map<String, dynamic>.from(raw);
        copy['image_url'] = imageUrl;
        copy['image_thumb_url'] = imageThumbUrl ??
            (imageUrl == null
                ? null
                : '/knowledge/nodes/$nodeId/image/file?variant=thumb');
        next.add(copy);
        changed = true;
      } else {
        next.add(raw);
      }
    }
    if (!changed) return;
    categoryGraph = {...graph, 'nodes': next};
    if (imageUrl != null) {
      imageBytesByUrl.removeWhere((key, _) => key.contains(nodeId));
      ensureImageCached(imageThumbUrl ?? '/knowledge/nodes/$nodeId/image/file?variant=thumb');
      ensureImageCached(imageUrl);
    }
    notifyListeners();
  }

  static String? _apiPathFromImageUrl(String imageUrl) {
    final trimmed = imageUrl.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('/api/v1/')) {
      return trimmed.substring('/api/v1'.length);
    }
    if (trimmed.startsWith('/knowledge/')) return trimmed;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    if (uri.path.contains('/api/v1/')) {
      final idx = uri.path.indexOf('/api/v1/');
      final path = uri.path.substring(idx + '/api/v1'.length);
      return uri.hasQuery ? '$path?${uri.query}' : path;
    }
    if (uri.path.startsWith('/knowledge/')) {
      return uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
    }
    return null;
  }

  /// POST focus; if a job is returned, track it without awaiting completion.
  Future<void> enqueueNeighborhood(String id, {String? title}) async {
    if (jobForNode(id) != null) {
      _ensurePoller();
      return;
    }
    try {
      final payload = await _post('/knowledge/focus', body: {'node_id': id, 'expand': true});
      final jobId = payload['job_id']?.toString();
      if (jobId == null) {
        // Already complete — adopt that graph and signal completion to the UI.
        final openedId = payload['focus_node_id']?.toString() ?? id;
        if (payload['nodes'] is List) {
          categoryGraph = payload;
        } else {
          categoryGraph = await _get('/knowledge/graph/$id');
        }
        if (focusHistory.isEmpty || focusHistory.last != (focusId ?? openedId)) {
          focusHistory.add(focusId ?? openedId);
        }
        lastCompletedNodeId = openedId;
        notifyListeners();
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

  void _trackJobFromPayload(
    Map<String, dynamic> payload, {
    required String id,
    String? title,
    String type = 'expand_neighborhood',
  }) {
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
        type: type,
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
      _applyPreferencesPayload(raw);
    } on ApiException {
      // Keep defaults when preferences are unavailable.
    }
  }

  Future<void> savePreferences(NeighborhoodPrefs next) async {
    prefs = next;
    notifyListeners();
    try {
      final raw = await _patch('/me/preferences', body: {
        'neighborhood': next.toJson(),
        'llm_provider': llmProvider,
      });
      _applyPreferencesPayload(raw);
      final id = focusId;
      if (id != null && !refreshing && !loading) {
        await openExisting(id);
      }
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
    }
  }

  Future<void> saveLlmProvider(String next) async {
    final provider = LlmProviderPref.normalize(next);
    llmProvider = provider;
    notifyListeners();
    try {
      final raw = await _patch('/me/preferences', body: {
        'llm_provider': provider,
        'neighborhood': prefs.toJson(),
      });
      _applyPreferencesPayload(raw);
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
    }
  }

  void _applyPreferencesPayload(Map<String, dynamic> raw) {
    final neighborhood = raw['neighborhood'];
    if (neighborhood is Map<String, dynamic>) {
      prefs = NeighborhoodPrefs.fromJson(neighborhood);
    }
    if (raw.containsKey('llm_provider')) {
      llmProvider = LlmProviderPref.normalize(raw['llm_provider']);
    }
    notifyListeners();
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
            type: item['type']?.toString() ?? 'expand_neighborhood',
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
            final resultFocus = result is Map
                ? (result['focus_id'] ?? result['node_id'])?.toString()
                : null;
            final loadId = resultFocus ?? tracked.nodeId;
            lastCompletedNodeId = loadId;
            lastCompletedJobType = tracked.type;
            if (tracked.type == 'generate_image') {
              final imageUrl = result is Map ? result['image_url']?.toString() : null;
              final thumbUrl = result is Map ? result['image_thumb_url']?.toString() : null;
              if (imageUrl != null && imageUrl.isNotEmpty) {
                patchNodeImageUrl(loadId, imageUrl, imageThumbUrl: thumbUrl);
              } else {
                try {
                  final meta = await _get('/knowledge/nodes/$loadId/image');
                  final url = meta['image_url']?.toString();
                  final thumb = meta['image_thumb_url']?.toString();
                  if (url != null && url.isNotEmpty) {
                    patchNodeImageUrl(loadId, url, imageThumbUrl: thumb);
                  }
                } on ApiException {
                  // Keep current graph.
                }
              }
            } else if (tracked.type != 'expand_content' &&
                (focusId == tracked.nodeId || focusId == loadId)) {
              // Soft-refresh neighborhood only for expand_neighborhood jobs.
              try {
                categoryGraph = await _get('/knowledge/graph/$loadId');
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
              error = job['error_message']?.toString() ??
                  (tracked.type == 'expand_content'
                      ? 'Content generation failed'
                      : tracked.type == 'generate_image'
                          ? 'Image generation failed'
                          : 'Neighborhood generation failed');
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

  Future<List<int>> _getBytes(String path) async {
    final fetch = bytesLoader;
    if (fetch != null) return fetch(path);
    final client = api;
    if (client == null) throw ApiException(0, 'NETWORK', 'API is not configured');
    return client.getBytes(path);
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
