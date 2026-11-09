import 'package:flutter/foundation.dart';

import '../../core/networking/api_client.dart';
import '../../core/networking/api_exception.dart';

class CategoryChoice {
  const CategoryChoice({required this.id, required this.title});

  final int id;
  final String title;
}

class GraphController extends ChangeNotifier {
  GraphController({this.api, this.loader});

  final ApiClient? api;
  final Future<Map<String, dynamic>> Function(String path)? loader;

  Map<String, dynamic>? categoryGraph;
  bool loading = false;
  bool refreshing = false;
  int? pendingNodeId;
  String? error;
  List<CategoryChoice> candidates = [];
  final List<int> focusHistory = [];

  int? get focusId {
    final raw = categoryGraph?['focus_node_id'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return null;
  }

  bool get canGoBack => focusHistory.length > 1 && !refreshing;

  Future<void> search(String topic) async {
    final trimmed = topic.trim();
    if (trimmed.isEmpty || refreshing || loading) return;
    final previous = List<int>.of(focusHistory);
    focusHistory.clear();
    await _load('/knowledge/graph?topic=${Uri.encodeQueryComponent(trimmed)}&up_depth=2&down_depth=2');
    if (error != null || candidates.isNotEmpty) {
      focusHistory
        ..clear()
        ..addAll(previous);
    }
  }

  Future<void> openCategory(int id) async {
    if (refreshing || loading) return;
    if (focusId == id && categoryGraph != null) return;
    pendingNodeId = id;
    await _load('/knowledge/graph?category_id=$id&up_depth=2&down_depth=2');
  }

  Future<void> choose(CategoryChoice choice) async {
    candidates = [];
    notifyListeners();
    await openCategory(choice.id);
  }

  Future<void> back() async {
    if (!canGoBack) return;
    final current = focusHistory.removeLast();
    final previous = focusHistory.last;
    await _load('/knowledge/graph?category_id=$previous&up_depth=2&down_depth=2', record: false);
    if (error != null) focusHistory.add(current);
  }

  Future<void> _load(String path, {bool record = true}) async {
    final first = categoryGraph == null;
    loading = first;
    refreshing = !first;
    error = null;
    candidates = [];
    notifyListeners();
    try {
      categoryGraph = await _get(path);
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
      pendingNodeId = null;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final fetch = loader;
    if (fetch != null) return Map<String, dynamic>.from(await fetch(path));
    final client = api;
    if (client == null) throw ApiException(0, 'NETWORK', 'API is not configured');
    return Map<String, dynamic>.from(await client.get(path) as Map);
  }

  List<CategoryChoice> _choices(Map<String, dynamic> details) {
    final raw = details['candidates'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map)
          CategoryChoice(
            id: (item['wikipedia_page_id'] as num).toInt(),
            title: item['title']?.toString() ?? 'Category',
          ),
    ];
  }
}
