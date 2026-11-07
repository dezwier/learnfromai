import 'package:flutter/widgets.dart';

import 'app.dart';
import 'core/config.dart';
import 'core/networking/api_client.dart';
import 'core/networking/token_storage.dart';
import 'features/auth/auth_controller.dart';
import 'features/auth/firebase_auth_gateway.dart';
import 'features/goals/goals_controller.dart';
import 'features/knowledge_graph/graph_controller.dart';
import 'features/learning/learn_controller.dart';
import 'features/mastery/mastery_controller.dart';
import 'features/review/review_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = const AppConfig();
  final tokens = SecureTokenStore();
  final api = ApiClient(baseUrl: config.baseUrl, tokens: tokens);
  final auth = AuthController(api: api, gateway: FirebaseAuthGateway());
  api.refreshIdToken = auth.refreshSession;
  final goals = GoalsController(api: api);
  final graph = GraphController(api: api);
  final learn = LearnController(api: api);
  final review = ReviewController(api: api);
  final mastery = MasteryController(api: api);
  await auth.loadMe();
  if (auth.user != null) {
    await goals.refresh();
    await graph.loadWorkspace();
    final goalId = goals.goal?['id']?.toString();
    if (goalId != null) await mastery.refresh(goalId);
    await review.refresh();
  }
  runApp(AdaptiveMasteryApp(auth: auth, goals: goals, graph: graph, learn: learn, review: review, mastery: mastery));
}
