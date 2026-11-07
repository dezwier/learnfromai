import 'package:go_router/go_router.dart';

import '../../features/auth/auth_controller.dart';
import '../../features/auth/sign_in_screen.dart';
import '../../features/knowledge_graph/graph_screen.dart';
import '../../features/learning/learn_screen.dart';
import '../../features/mastery/mastery_screen.dart';
import '../../features/onboarding/onboarding_screen.dart';
import '../../features/review/review_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/trajectory/trajectory_screen.dart';
import '../../shell/app_shell.dart';

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
      GoRoute(path: '/onboarding', pageBuilder: (context, state) => const NoTransitionPage(child: OnboardingScreen())),
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(path: '/graph', pageBuilder: (context, state) => const NoTransitionPage(child: GraphScreen())),
          GoRoute(path: '/trajectory', pageBuilder: (context, state) => const NoTransitionPage(child: TrajectoryScreen())),
          GoRoute(path: '/learn', pageBuilder: (context, state) => const NoTransitionPage(child: LearnScreen())),
          GoRoute(path: '/review', pageBuilder: (context, state) => const NoTransitionPage(child: ReviewScreen())),
          GoRoute(path: '/mastery', pageBuilder: (context, state) => const NoTransitionPage(child: MasteryScreen())),
          GoRoute(path: '/settings', pageBuilder: (context, state) => const NoTransitionPage(child: SettingsScreen())),
        ],
      ),
    ],
  );
}
