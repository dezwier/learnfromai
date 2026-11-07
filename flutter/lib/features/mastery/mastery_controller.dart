import 'package:flutter/foundation.dart';

import '../../core/networking/api_client.dart';
import '../../core/networking/api_exception.dart';

class MasteryController extends ChangeNotifier {
  MasteryController({this.api});

  final ApiClient? api;
  Map<String, dynamic>? overview;
  List<Map<String, dynamic>> changes = [];
  bool loading = false;
  String? error;

  Future<void> refresh(String goalId) async {
    final client = api;
    if (client == null) return;
    loading = true;
    notifyListeners();
    try {
      overview = Map<String, dynamic>.from(await client.get('/mastery/overview?goal_id=$goalId') as Map);
      final history = Map<String, dynamic>.from(await client.get('/goals/$goalId/graph-changes') as Map);
      changes = [for (final item in (history['migrations'] as List? ?? [])) Map<String, dynamic>.from(item as Map)];
      error = null;
    } on ApiException catch (exc) {
      error = exc.message;
    } finally {
      loading = false;
      notifyListeners();
    }
  }
}
