import 'package:flutter/widgets.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

import 'app.dart';
import 'core/config.dart';
import 'core/networking/api_client.dart';
import 'core/networking/token_storage.dart';
import 'core/theme/theme_controller.dart';
import 'features/auth/auth_controller.dart';
import 'features/auth/firebase_auth_gateway.dart';
import 'features/knowledge_graph/graph_controller.dart';

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: binding);

  // Resolve theme before the first frame so splash isn't stuck on system-light white.
  final initialTheme = await ThemeController.readLastMode();

  final config = const AppConfig();
  final tokens = SecureTokenStore();
  final api = ApiClient(baseUrl: config.baseUrl, tokens: tokens);
  final auth = AuthController(api: api, gateway: FirebaseAuthGateway());
  api.refreshIdToken = auth.refreshSession;
  final graph = GraphController(api: api);

  runApp(
    AdaptiveMasteryApp(
      auth: auth,
      graph: graph,
      initialThemeMode: initialTheme,
    ),
  );
}
