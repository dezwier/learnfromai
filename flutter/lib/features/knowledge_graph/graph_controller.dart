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
  }

  Future<void> extend(String instruction, {String? parentConceptId}) async {
    final client = api;
    if (client == null) return;
    extending = true;
    error = null;
    notifyListeners();
    try {
      final body = <String, dynamic>{'instruction': instruction};
      if (parentConceptId != null) body['parent_concept_id'] = parentConceptId;
      final queued = Map<String, dynamic>.from(await client.post('/graph/extend', body: body) as Map);
      final jobId = queued['job_id']?.toString();
      if (jobId != null) {
        for (var attempt = 0; attempt < 40; attempt++) {
          final job = Map<String, dynamic>.from(await client.get('/jobs/$jobId') as Map);
          final state = job['state']?.toString();
          if (state == 'succeeded') break;
          if (state == 'failed') {
            error = job['error_code']?.toString() ?? 'Extend failed';
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
      workspace = Map<String, dynamic>.from(await client.get('/workspace/graph') as Map);
    } on ApiException catch (exc) {
      error = exc.message;
    } finally {
      extending = false;
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
