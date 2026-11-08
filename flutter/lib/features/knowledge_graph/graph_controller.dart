import 'package:flutter/foundation.dart';

import '../../core/networking/api_client.dart';
import '../../core/networking/api_exception.dart';

class GraphController extends ChangeNotifier {
  GraphController({this.api});

  final ApiClient? api;
  Map<String, dynamic>? workspace;
  bool loading = false;
  bool extending = false;
  bool deleting = false;
  String? error;
  String? progressMessage;
  double progressFraction = 0.2;
  String? generationInstruction;
  bool _following = false;

  bool get generationPending => extending || _pendingRequest() != null;

  String get generationLabel {
    if (progressMessage != null && progressMessage!.isNotEmpty) return progressMessage!;
    final pending = _pendingRequest();
    final message = pending?['progress_message']?.toString();
    if (message != null && message.isNotEmpty) return message;
    return 'Waiting to generate';
  }

  String get generationSubject {
    final instruction = generationInstruction ?? _pendingRequest()?['instruction']?.toString();
    if (instruction != null && instruction.isNotEmpty) return instruction;
    return 'The graph';
  }

  double get generationFraction {
    if (extending) return progressFraction;
    final raw = _pendingRequest()?['progress_fraction'];
    if (raw is num) return raw.toDouble();
    return 0.2;
  }

  Map<String, dynamic>? _pendingRequest() {
    for (final raw in (workspace?['extend_requests'] as List?) ?? const []) {
      if (raw is! Map) continue;
      final request = Map<String, dynamic>.from(raw);
      final status = request['status']?.toString();
      if (status == 'queued' || status == 'running') return request;
    }
    return null;
  }

  Future<void> load() async {
    final client = api;
    if (client == null) return;
    loading = true;
    notifyListeners();
    try {
      workspace = Map<String, dynamic>.from(await client.get('/workspace/graph') as Map);
      error = null;
    } on ApiException catch (exc) {
      error = exc.message;
    } finally {
      loading = false;
      notifyListeners();
    }
    final pending = _pendingRequest();
    final jobId = pending?['job_id']?.toString();
    if (pending != null && jobId != null && !_following) {
      generationInstruction = pending['instruction']?.toString();
      progressMessage = pending['progress_message']?.toString() ?? 'Waiting to generate';
      final fraction = pending['progress_fraction'];
      progressFraction = fraction is num ? fraction.toDouble() : 0.2;
      extending = true;
      notifyListeners();
      await _follow(jobId);
    }
  }

  Future<void> extend(String instruction, {String? parentConceptId}) async {
    final client = api;
    if (client == null) return;
    extending = true;
    error = null;
    generationInstruction = instruction;
    progressMessage = 'Waiting to generate';
    progressFraction = 0.2;
    notifyListeners();
    try {
      final body = <String, dynamic>{'instruction': instruction};
      if (parentConceptId != null) body['parent_concept_id'] = parentConceptId;
      final queued = Map<String, dynamic>.from(await client.post('/graph/extend', body: body) as Map);
      final jobId = queued['job_id']?.toString();
      if (jobId != null) await _follow(jobId);
      workspace = Map<String, dynamic>.from(await client.get('/workspace/graph') as Map);
    } on ApiException catch (exc) {
      error = exc.message;
    } finally {
      final stillPending = _pendingRequest() != null && error == null;
      extending = stillPending;
      if (!stillPending) {
        generationInstruction = null;
        progressMessage = null;
      }
      notifyListeners();
    }
  }

  Future<void> _follow(String jobId) async {
    final client = api;
    if (client == null || _following) return;
    _following = true;
    try {
      for (var attempt = 0; attempt < 200; attempt++) {
        final job = Map<String, dynamic>.from(await client.get('/jobs/$jobId') as Map);
        final progress = job['progress'];
        if (progress is Map) {
          final message = progress['message']?.toString();
          if (message != null && message.isNotEmpty) progressMessage = message;
          final fraction = progress['fraction'];
          if (fraction is num) progressFraction = fraction.toDouble();
        }
        final state = job['state']?.toString();
        if (state == 'queued' && (progressMessage == null || progressMessage!.isEmpty)) {
          progressMessage = 'Waiting to generate';
        }
        notifyListeners();
        if (state == 'succeeded') return;
        if (state == 'failed') {
          final message = job['error_message']?.toString();
          error = message != null && message.isNotEmpty ? message : 'The graph could not be generated';
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    } on ApiException catch (exc) {
      error = exc.message;
    } finally {
      _following = false;
    }
  }

  Future<void> clearGraph() async {
    final client = api;
    if (client == null) return;
    deleting = true;
    error = null;
    notifyListeners();
    try {
      await client.delete('/graph');
      workspace = Map<String, dynamic>.from(await client.get('/workspace/graph') as Map);
    } on ApiException catch (exc) {
      error = exc.message;
    } finally {
      deleting = false;
      notifyListeners();
    }
  }

  Future<void> deleteNode(String conceptId) async {
    final client = api;
    if (client == null) return;
    deleting = true;
    error = null;
    notifyListeners();
    try {
      await client.delete('/graph/nodes/$conceptId');
      workspace = Map<String, dynamic>.from(await client.get('/workspace/graph') as Map);
    } on ApiException catch (exc) {
      error = exc.message;
    } finally {
      deleting = false;
      notifyListeners();
    }
  }
}
