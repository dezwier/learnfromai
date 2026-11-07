import 'package:flutter/foundation.dart';

import '../../core/networking/api_client.dart';
import '../../core/networking/api_exception.dart';

class LearnController extends ChangeNotifier {
  LearnController({this.api});

  final ApiClient? api;
  String? sessionId;
  Map<String, dynamic>? activity;
  Map<String, dynamic>? feedback;
  bool loading = false;
  String? error;

  Future<void> start(String goalId, {String? conceptId}) async {
    final client = api;
    if (client == null) return;
    loading = true;
    feedback = null;
    notifyListeners();
    try {
      final opened = Map<String, dynamic>.from(
        await client.post('/learning-sessions', body: {'goal_id': goalId, 'concept_id': ?conceptId}) as Map,
      );
      sessionId = opened['session_id'].toString();
      await _loadNext();
    } on ApiException catch (exc) {
      error = exc.message;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> continueLesson() async {
    final client = api;
    if (client == null || sessionId == null || activity == null) return;
    loading = true;
    feedback = null;
    notifyListeners();
    try {
      await client.post(
        '/learning-sessions/$sessionId/attempts',
        body: {'activity_id': activity!['id'], 'answer': <String, dynamic>{}},
        idempotencyKey: 'read-${activity!['id']}',
      );
      activity = null;
      await _loadNext();
      error = null;
    } on ApiException catch (exc) {
      error = exc.message;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> submit(String text) async {
    final client = api;
    if (client == null || sessionId == null || activity == null) return;
    loading = true;
    notifyListeners();
    try {
      feedback = Map<String, dynamic>.from(
        await client.post(
          '/learning-sessions/$sessionId/attempts',
          body: {'activity_id': activity!['id'], 'answer': {'text': text}},
          idempotencyKey: 'learn-${activity!['id']}-$text',
        ) as Map,
      );
      error = null;
    } on ApiException catch (exc) {
      error = exc.message;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> _loadNext() async {
    final client = api;
    if (client == null || sessionId == null) return;
    for (var attempt = 0; attempt < 20; attempt++) {
      final payload = Map<String, dynamic>.from(await client.get('/learning-sessions/$sessionId/next') as Map);
      if (payload['status'] == 'ready') {
        activity = Map<String, dynamic>.from(payload['activity'] as Map);
        return;
      }
      if (payload['status'] == 'complete') {
        activity = null;
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }
}
