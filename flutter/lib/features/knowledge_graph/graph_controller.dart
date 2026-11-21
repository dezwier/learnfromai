import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../core/networking/api_client.dart';
import '../../core/networking/api_exception.dart';
import 'models.dart';
export 'models.dart';

part 'graph_images.dart';

class GraphController extends ChangeNotifier {
  GraphController({
    this.api,
    this.loader,
    this.poster,
    this.patcher,
    this.deleter,
    this.jobLoader,
    this.bytesLoader,
    this.uploader,
  });

  final ApiClient? api;
  final Future<Map<String, dynamic>> Function(String path)? loader;
  final Future<Map<String, dynamic>> Function(String path, {Object? body})? poster;
  final Future<Map<String, dynamic>> Function(String path, {Object? body})? patcher;
  final Future<Map<String, dynamic>> Function(String path)? deleter;
  final Future<Map<String, dynamic>> Function(String jobId)? jobLoader;
  final Future<List<int>> Function(String path)? bytesLoader;
  final Future<Map<String, dynamic>> Function(
    String path, {
    required List<int> bytes,
    required String filename,
    String? contentType,
  })? uploader;

  Map<String, dynamic>? categoryGraph;
  bool loading = false;
  bool refreshing = false;
  String? error;

  void clearError() {
    if (error == null) return;
    error = null;
    notifyListeners();
  }

  /// Show [message] on the global status badge (replaces any prior notice).
  void surfaceError(String message) {
    final trimmed = message.trim();
    if (trimmed.isEmpty || error == trimmed) return;
    error = trimmed;
    notifyListeners();
  }
  List<TopicChoice> candidates = [];
  List<TopicChoice> suggestions = [];
  final List<String> focusHistory = [];
  /// Titles for [focusHistory] badges (id → label), kept for nodes no longer on canvas.
  final Map<String, String> _focusTitles = {};
  static const int maxFocusTrail = 10;
  NeighborhoodPrefs prefs = const NeighborhoodPrefs();
  String llmProvider = LlmProviderPref.openai;
  final List<TrackedJob> trackedJobs = [];
  /// Set when an expand job succeeds; UI consumes then [clearLastCompleted].
  String? lastCompletedNodeId;
  String? lastCompletedJobType;
  /// Auth-fetched image bytes keyed by API image path (full or thumb).
  final Map<String, Uint8List> imageBytesByUrl = {};
  final Map<String, Future<Uint8List?>> _imageFetchesInFlight = {};
  final Set<String> _imageLoadsInFlight = {};
  int _suggestToken = 0;
  Timer? _jobPoller;
  var _polling = false;
  var _disposed = false;
  Future<void>? _resumeInFlight;

  String? get focusId {
    final raw = categoryGraph?['focus_node_id'];
    if (raw == null) return null;
    return raw.toString();
  }

  bool get canGoBack => focusHistory.length > 1 && !refreshing;

  /// Oldest → newest prior focuses for the bottom breadcrumb (excludes current).
  List<FocusTrailEntry> get focusTrail {
    if (focusHistory.length <= 1) return const [];
    return [
      for (final id in focusHistory.sublist(0, focusHistory.length - 1))
        FocusTrailEntry(
          id: id,
          title: _focusTitles[id] ?? _titleForNode(id) ?? 'Topic',
        ),
    ];
  }

  void _recordFocus(String id, {String? title}) {
    final label = title?.trim();
    if (label != null && label.isNotEmpty) {
      _focusTitles[id] = label;
    } else {
      final known = _titleForNode(id);
      if (known != null && known.trim().isNotEmpty) {
        _focusTitles[id] = known.trim();
      }
    }
    if (focusHistory.isNotEmpty && focusHistory.last == id) return;
    // Keep ids unique: revisiting a topic moves it to the end (no duplicate chips).
    focusHistory.remove(id);
    focusHistory.add(id);
    while (focusHistory.length > maxFocusTrail) {
      final dropped = focusHistory.removeAt(0);
      if (!focusHistory.contains(dropped)) _focusTitles.remove(dropped);
    }
  }

  /// Jump to a trail entry; drops anything newer so right stays most recent.
  Future<void> openTrailEntry(String id) async {
    if (refreshing || loading) return;
    final idx = focusHistory.lastIndexOf(id);
    if (idx >= 0 && idx < focusHistory.length - 1) {
      focusHistory.removeRange(idx + 1, focusHistory.length);
    }
    await openExisting(
      id,
      title: _focusTitles[id] ?? _titleForNode(id),
      interestSource: 'graph',
    );
  }

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

  /// Active job for [nodeId]. When [type] is set, only that job kind matches.
  TrackedJob? jobForNode(String nodeId, {String? type}) {
    for (final job in trackedJobs) {
      if (!job.isActive || job.nodeId != nodeId) continue;
      if (type == null || job.type == type) return job;
    }
    return null;
  }

  bool isJobTypeActive(String nodeId, String type) =>
      jobForNode(nodeId, type: type) != null;

  /// Pull active jobs for a node (any user) and track them so same-type actions can disable.
  Future<void> syncNodeJobs(String id, {String? title}) async {
    try {
      final raw = await _get('/knowledge/nodes/$id/jobs');
      final list = raw['jobs'];
      if (list is! List) return;
      for (final item in list) {
        if (item is! Map) continue;
        final jobId = item['id']?.toString();
        final nodeId = item['focus_node_id']?.toString() ?? id;
        if (jobId == null) continue;
        final progress = item['progress'];
        _upsertTracked(
          TrackedJob(
            jobId: jobId,
            nodeId: nodeId,
            title: item['title']?.toString() ?? title ?? _titleForNode(nodeId) ?? 'Topic',
            state: item['state']?.toString() ?? 'queued',
            type: item['type']?.toString() ?? 'expand_neighborhood',
            progressMessage: progress is Map ? progress['message']?.toString() : null,
            fraction: progress is Map ? (progress['fraction'] as num?)?.toDouble() ?? 0 : 0,
          ),
        );
      }
      if (trackedJobs.any((j) => j.isActive)) _ensurePoller();
    } on ApiException {
      // Drawer still works from locally tracked jobs.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _jobPoller?.cancel();
    _jobPoller = null;
    super.dispose();
  }

  /// Cold start / foreground: load prefs + latest neighborhood. Concurrent callers share one run.
  Future<void> resume() {
    final existing = _resumeInFlight;
    if (existing != null) return existing;
    late final Future<void> future;
    future = _resumeBody().whenComplete(() {
      if (identical(_resumeInFlight, future)) _resumeInFlight = null;
    });
    _resumeInFlight = future;
    return future;
  }

  Future<void> _resumeBody() async {
    await loadPreferences();
    if (categoryGraph == null && candidates.isEmpty) {
      // Wait out a concurrent open/focus instead of no-oping while loading.
      while ((loading || refreshing) && categoryGraph == null && candidates.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
        if (_disposed) return;
      }
      if (categoryGraph == null && candidates.isEmpty && !loading && !refreshing) {
        await _focus(body: const {});
      }
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
      return;
    }
    final id = focusId;
    if (id != null) {
      unawaited(
        trackEvent(nodeId: id, kind: 'open', payload: {'source': 'search'}),
      );
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
  ///
  /// Pass [interestSource] (`graph` / `search` / `list` / `settings`) to record
  /// an intentional open for affinity. Omit for internal refreshes.
  Future<void> openExisting(
    String id, {
    String? title,
    Map<String, dynamic>? knownPayload,
    String? interestSource,
  }) async {
    if (refreshing || loading) return;
    if (focusId == id && categoryGraph != null && knownPayload == null) {
      suggestions = [];
      notifyListeners();
      if (interestSource != null && interestSource.isNotEmpty) {
        unawaited(
          trackEvent(
            nodeId: id,
            kind: 'open',
            payload: {'source': interestSource},
          ),
        );
      }
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
      _recordFocus(openedId, title: title ?? _titleForNode(openedId));
      if (interestSource != null && interestSource.isNotEmpty) {
        unawaited(
          trackEvent(
            nodeId: openedId,
            kind: 'open',
            payload: {'source': interestSource},
          ),
        );
      }
    } on ApiException catch (exc) {
      error = exc.message;
    } finally {
      loading = false;
      refreshing = false;
      notifyListeners();
    }
  }

  /// GET shared learn / example / check1–3 bits (never enqueues).
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

  /// Next unlearned atomic pack on seed or a neighbor (exploit / explore).
  ///
  /// Pass [excludeNodeId] + [excludePackIndex] to skip the on-screen pack when
  /// prefetching the following card.
  Future<LearningNext?> fetchLearningNext(
    String seedNodeId, {
    String? excludeNodeId,
    int? excludePackIndex,
  }) async {
    try {
      final params = <String>['seed_node_id=$seedNodeId'];
      if (excludeNodeId != null &&
          excludeNodeId.isNotEmpty &&
          excludePackIndex != null &&
          excludePackIndex > 0) {
        params.add('exclude_node_id=$excludeNodeId');
        params.add('exclude_pack_index=$excludePackIndex');
      }
      final raw = await _get('/me/learning-next?${params.join('&')}');
      return LearningNext.fromJson(raw);
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
      return null;
    }
  }

  /// Image metadata for a node not present in the current neighborhood graph.
  Future<({String? imageUrl, String? imageThumbUrl})?> fetchNodeImageMeta(String nodeId) async {
    try {
      final raw = await _get('/knowledge/nodes/$nodeId/image');
      final url = raw['image_url']?.toString().trim();
      final thumb = raw['image_thumb_url']?.toString().trim();
      return (
        imageUrl: (url == null || url.isEmpty) ? null : url,
        imageThumbUrl: (thumb == null || thumb.isEmpty) ? null : thumb,
      );
    } on ApiException {
      return null;
    }
  }

  /// Request shared content expand when incomplete; track the job like neighborhood.
  Future<TopicContent?> enqueueContent(
    String id, {
    String? title,
    bool newPack = false,
  }) async {
    if (isJobTypeActive(id, 'expand_content')) {
      _ensurePoller();
      return fetchContent(id);
    }
    try {
      final payload = await _post(
        '/knowledge/nodes/$id/content',
        body: {
          'expand': true,
          if (newPack) 'new_pack': true,
        },
      );
      final jobId = payload['job_id']?.toString();
      if (jobId == null) {
        return TopicContent.fromJson(payload);
      }
      _trackJobFromPayload(payload, id: id, title: title, type: 'expand_content');
      return TopicContent(
        nodeId: payload['focus_node_id']?.toString() ?? id,
        incomplete: true,
        packs: const [],
      );
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
      return null;
    }
  }

  /// Learning-track generate: fill an incomplete pack, else create the next one.
  ///
  /// Plain [enqueueContent] returns 200 when packs are already content-complete,
  /// which loops forever with learning-next `generate` after the user finishes them.
  Future<TopicContent?> enqueueContentForTrack(String id, {String? title}) async {
    if (isJobTypeActive(id, 'expand_content')) {
      _ensurePoller();
      return fetchContent(id);
    }
    final existing = await fetchContent(id);
    final packs = existing?.packs ?? const <TopicPack>[];
    final hasIncomplete = packs.any((pack) => pack.incomplete);
    final newPack = packs.isNotEmpty && !hasIncomplete;
    return enqueueContent(id, title: title, newPack: newPack);
  }

  /// Leitner hub chart + due count for the testing track.
  Future<LeitnerDistribution?> fetchReviewDistribution() async {
    try {
      final raw = await _get('/me/reviews/distribution');
      return LeitnerDistribution.fromJson(raw);
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
      return null;
    }
  }

  /// Due packs for a review session (capped server-side).
  Future<ReviewDueQueue?> fetchReviewDue({int limit = 10}) async {
    try {
      final raw = await _get('/me/reviews/due?limit=$limit');
      return ReviewDueQueue.fromJson(raw);
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
      return null;
    }
  }

  /// Submit one testing-track answer and apply Leitner moves.
  Future<ReviewSubmitResult?> submitReview({
    required String nodeId,
    required int packIndex,
    required bool correct,
    required String checkKind,
    int? choiceIndex,
    bool? answerBool,
    String? answerText,
  }) async {
    try {
      final raw = await _post(
        '/me/reviews/submit',
        body: {
          'node_id': nodeId,
          'pack_index': packIndex,
          'correct': correct,
          'check_kind': checkKind,
          if (choiceIndex != null) 'choice_index': choiceIndex,
          if (answerBool != null) 'answer_bool': answerBool,
          if (answerText != null) 'answer_text': answerText,
        },
      );
      return ReviewSubmitResult.fromJson(raw);
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
      return null;
    }
  }

  /// Fire-and-forget learn/example/check interaction (never blocks UI).
  Future<void> trackEvent({
    required String nodeId,
    required String kind,
    Map<String, dynamic>? payload,
    DateTime? occurredAt,
  }) async {
    try {
      await _post(
        '/me/events',
        body: {
          'events': [
            {
              'node_id': nodeId,
              'kind': kind,
              'occurred_at': (occurredAt ?? DateTime.now().toUtc()).toIso8601String(),
              if (payload != null) 'payload': payload,
            },
          ],
        },
      );
    } catch (_) {
      // Telemetry must not affect learning UX.
    }
  }

  /// Profile affinity map: scored topics + edge clusters.
  Future<Map<String, dynamic>?> fetchTopicAffinity({int limit = 24}) async {
    try {
      return await _get('/me/topic-affinity?limit=$limit');
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
      return null;
    }
  }

  /// POST focus; if a job is returned, track it without awaiting completion.
  Future<void> enqueueNeighborhood(String id, {String? title}) async {
    if (isJobTypeActive(id, 'expand_neighborhood')) {
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
        _recordFocus(focusId ?? openedId, title: title ?? _titleForNode(focusId ?? openedId));
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
    await openExisting(choice.id, title: choice.title, interestSource: 'search');
  }

  Future<void> back() async {
    if (!canGoBack) return;
    final current = focusHistory.removeLast();
    final previous = focusHistory.last;
    await openExisting(previous, interestSource: 'graph');
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

  /// Admin: delete one quiz bit (or the whole pack when [confirmLastPack]).
  Future<Map<String, dynamic>?> adminDeleteQuiz({
    required String nodeId,
    required int packIndex,
    required String checkKind,
    bool confirmLastPack = false,
  }) async {
    error = null;
    try {
      final q = confirmLastPack ? '?confirm_last_pack=true' : '';
      return await _delete(
        '/admin/knowledge/nodes/$nodeId/packs/$packIndex/bits/$checkKind$q',
      );
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
      rethrow;
    }
  }

  /// Admin: delete a shared pack (+ events + Leitner rows).
  Future<Map<String, dynamic>?> adminDeletePack({
    required String nodeId,
    required int packIndex,
  }) async {
    error = null;
    try {
      return await _delete('/admin/knowledge/nodes/$nodeId/packs/$packIndex');
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
      return null;
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
      if (record && id != null) {
        _recordFocus(
          id,
          title: body['topic']?.toString() ?? _titleForNode(id),
        );
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
    // Key by jobId only so different types can run on the same node.
    final index = trackedJobs.indexWhere((j) => j.jobId == job.jobId);
    if (index >= 0) {
      final previous = trackedJobs[index];
      if (previous.jobId == job.jobId &&
          previous.nodeId == job.nodeId &&
          previous.state == job.state &&
          previous.type == job.type &&
          previous.progressMessage == job.progressMessage &&
          previous.fraction == job.fraction &&
          previous.title == job.title) {
        return;
      }
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

  Future<Map<String, dynamic>> _upload(
    String path, {
    required List<int> bytes,
    required String filename,
    String? contentType,
  }) async {
    final upload = uploader;
    if (upload != null) {
      return Map<String, dynamic>.from(
        await upload(path, bytes: bytes, filename: filename, contentType: contentType),
      );
    }
    final client = api;
    if (client == null) throw ApiException(0, 'NETWORK', 'API is not configured');
    return Map<String, dynamic>.from(
      await client.putMultipart(
        path,
        bytes: bytes,
        filename: filename,
        contentType: contentType,
      ) as Map,
    );
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
