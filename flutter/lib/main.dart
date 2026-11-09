import 'package:flutter/widgets.dart';

import 'app.dart';
import 'core/config.dart';
import 'core/networking/api_client.dart';
import 'core/networking/token_storage.dart';
import 'features/auth/auth_controller.dart';
import 'features/auth/firebase_auth_gateway.dart';
import 'features/knowledge_graph/graph_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = const AppConfig();
  final tokens = SecureTokenStore();
  final api = ApiClient(baseUrl: config.baseUrl, tokens: tokens);
  final auth = AuthController(api: api, gateway: FirebaseAuthGateway());
  api.refreshIdToken = auth.refreshSession;
  final graph = GraphController(api: api);
  await auth.loadMe();
  runApp(AdaptiveMasteryApp(auth: auth, graph: graph));
}
