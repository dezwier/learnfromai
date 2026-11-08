import 'package:go_router/go_router.dart';

import '../../features/auth/auth_controller.dart';
import '../../features/auth/sign_in_screen.dart';
import '../../features/knowledge_graph/graph_screen.dart';

GoRouter buildRouter(AuthController auth) {
  return GoRouter(
    initialLocation: '/graph',
    refreshListenable: auth,
    redirect: (context, state) {
      final signedIn = auth.user != null;
      final signingIn = state.uri.path == '/sign-in';
      if (!signedIn && !signingIn) return '/sign-in';
      if (signedIn && signingIn) return '/graph';
      return null;
    },
    routes: [
      GoRoute(path: '/sign-in', pageBuilder: (context, state) => const NoTransitionPage(child: SignInScreen())),
      GoRoute(path: '/graph', pageBuilder: (context, state) => const NoTransitionPage(child: GraphScreen())),
    ],
  );
}
