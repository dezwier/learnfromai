import 'package:flutter/foundation.dart';

import '../../core/networking/api_client.dart';
import '../../core/networking/api_exception.dart';

class ReviewController extends ChangeNotifier {
  ReviewController({this.api});

  final ApiClient? api;
  List<Map<String, dynamic>> due = [];
  Map<String, dynamic>? feedback;
  bool revealed = false;
  bool loading = false;
  String? error;

  Future<void> refresh() async {
    final client = api;
    if (client == null) return;
    loading = true;
    notifyListeners();
    try {
      final payload = Map<String, dynamic>.from(await client.get('/reviews/due') as Map);
      due = [for (final item in (payload['items'] as List? ?? [])) Map<String, dynamic>.from(item as Map)];
      error = null;
    } on ApiException catch (exc) {
      error = exc.message;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void reveal() {
    revealed = true;
    notifyListeners();
  }

  Future<void> submit(String itemId, String text) async {
    final client = api;
    if (client == null) return;
    try {
      feedback = Map<String, dynamic>.from(
        await client.post('/reviews/$itemId/submit', body: {'answer': {'text': text}}, idempotencyKey: 'review-$itemId') as Map,
      );
      revealed = true;
      error = null;
    } on ApiException catch (exc) {
      error = exc.message;
    }
    notifyListeners();
  }
}
