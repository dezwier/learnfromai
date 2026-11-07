import 'package:flutter/foundation.dart';

import '../../core/networking/api_client.dart';
import '../../core/networking/api_exception.dart';

class GraphController extends ChangeNotifier {
  GraphController({this.api});

  final ApiClient? api;
  Map<String, dynamic>? tree;
  Map<String, dynamic>? workspace;
  Map<String, dynamic>? detail;
  Map<String, dynamic>? impact;
  String? proposalId;
  String? proposalGraphId;
  String? trajectoryId;
  bool loading = false;
  String? error;
  String query = '';

  Future<void> focusTrajectory(String? id) async {
    trajectoryId = id;
    await loadWorkspace();
  }

  Future<void> loadWorkspace() async {
    final client = api;
    if (client == null) return;
    loading = true;
    notifyListeners();
    try {
      final path = trajectoryId == null ? '/workspace/graph' : '/workspace/graph?trajectory_id=$trajectoryId';
      workspace = Map<String, dynamic>.from(await client.get(path) as Map);
      error = null;
    } on ApiException catch (exc) {
      error = exc.message;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> accept(String goalId) async {
    final client = api;
    final proposal = proposalId;
    final graphId = proposalGraphId;
    if (client == null || proposal == null || graphId == null) return;
    loading = true;
    notifyListeners();
    try {
      await client.post('/graphs/$graphId/proposals/$proposal/accept-private?goal_id=$goalId');
      proposalId = null;
      impact = null;
      error = null;
      final path = trajectoryId == null ? '/workspace/graph' : '/workspace/graph?trajectory_id=$trajectoryId';
      workspace = Map<String, dynamic>.from(await client.get(path) as Map);
    } on ApiException catch (exc) {
      error = exc.message;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> load(String graphId, {String? releaseId}) async {
    final client = api;
    if (client == null) return;
    loading = true;
    notifyListeners();
    try {
      final suffix = releaseId == null ? '' : '?release_id=$releaseId';
      tree = Map<String, dynamic>.from(await client.get('/graphs/$graphId/tree$suffix') as Map);
      error = null;
    } on ApiException catch (exc) {
      error = exc.message;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> openConcept(String graphId, String conceptId) async {
    final client = api;
    if (client == null) return;
    detail = Map<String, dynamic>.from(await client.get('/graphs/$graphId/concepts/$conceptId') as Map);
    notifyListeners();
  }

  Future<void> expand(String graphId, String releaseId, String parentId, String instruction) async {
    final client = api;
    if (client == null) return;
    loading = true;
    notifyListeners();
    try {
      final queued = Map<String, dynamic>.from(
        await client.post(
          '/graphs/$graphId/expansions',
          body: {'base_release_id': releaseId, 'parent_concept_id': parentId, 'instruction': instruction, 'max_depth': 2, 'max_new_concepts': 12, 'visibility': 'private'},
        ) as Map,
      );
      for (var attempt = 0; attempt < 20; attempt++) {
        final job = Map<String, dynamic>.from(await client.get('/jobs/${queued['job_id']}') as Map);
        if (job['state'] == 'succeeded') {
          final proposed = (job['result'] as Map?)?['proposal_id']?.toString();
          if (proposed != null) {
            proposalId = proposed;
            proposalGraphId = graphId;
            impact = Map<String, dynamic>.from(await client.get('/graphs/$graphId/migration-preview?proposal_id=$proposed') as Map);
          }
          final path = trajectoryId == null ? '/workspace/graph' : '/workspace/graph?trajectory_id=$trajectoryId';
      workspace = Map<String, dynamic>.from(await client.get(path) as Map);
          break;
        }
        if (job['state'] == 'failed') {
          error = job['error_code']?.toString();
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    } on ApiException catch (exc) {
      error = exc.message;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void setQuery(String value) {
    query = value;
    notifyListeners();
  }

  void showLocalDetail(Map<String, dynamic> node) {
    detail = node;
    notifyListeners();
  }
}
