import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/networking/api_client.dart';
import '../../core/networking/api_exception.dart';

class GoalsController extends ChangeNotifier {
  GoalsController({this.api});

  final ApiClient? api;
  List<Map<String, dynamic>> goals = [];
  Map<String, dynamic>? goal;
  Map<String, dynamic>? recommendation;
  Map<String, dynamic>? trajectory;
  bool loading = false;
  String? error;
  String? jobStatus;

  Future<void> refresh() async {
    final client = api;
    if (client == null) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final payload = Map<String, dynamic>.from(await client.get('/goals') as Map);
      final rows = (payload['goals'] as List?) ?? [];
      goals = [for (final row in rows) Map<String, dynamic>.from(row as Map)];
      goal = goals.isEmpty ? null : goals.first;
      if (goal != null && goal!['status'] == 'active') {
        recommendation = Map<String, dynamic>.from(await client.get('/goals/${goal!['id']}/recommendation') as Map);
        try {
          trajectory = Map<String, dynamic>.from(await client.get('/goals/${goal!['id']}/trajectory') as Map);
        } on ApiException {
          trajectory = null;
        }
      }
    } on ApiException catch (exc) {
      error = exc.message;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> createGoal({required String topic, required String purpose, required String depth, required int minutes}) async {
    final client = api;
    if (client == null) return;
    loading = true;
    jobStatus = 'Preparing your map';
    notifyListeners();
    try {
      final created = Map<String, dynamic>.from(
        await client.post('/goals', body: {'topic': topic, 'purpose': purpose, 'target_depth': depth, 'minutes_per_week': minutes, 'language': 'en'}) as Map,
      );
      await _poll(created['job_id'].toString());
      await refresh();
    } on ApiException catch (exc) {
      error = exc.message;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<bool> rename(String id, String title) async {
    final client = api;
    if (client == null || title.trim().isEmpty) return false;
    try {
      await client.patch('/goals/$id', body: {'title': title.trim()});
      await refresh();
      return true;
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
      return false;
    }
  }

  Future<bool> remove(String id) async {
    final client = api;
    if (client == null) return false;
    try {
      await client.delete('/goals/$id');
      await refresh();
      return true;
    } on ApiException catch (exc) {
      error = exc.message;
      notifyListeners();
      return false;
    }
  }

  Future<void> _poll(String jobId) async {
    final client = api;
    if (client == null) return;
    for (var attempt = 0; attempt < 20; attempt++) {
      final job = Map<String, dynamic>.from(await client.get('/jobs/$jobId') as Map);
      jobStatus = job['state']?.toString();
      notifyListeners();
      if (job['state'] == 'succeeded' || job['state'] == 'failed') return;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }
}
