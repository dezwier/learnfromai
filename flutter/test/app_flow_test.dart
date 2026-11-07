import 'package:adaptive_mastery/app.dart';
import 'package:adaptive_mastery/core/networking/api_client.dart';
import 'package:adaptive_mastery/core/networking/api_exception.dart';
import 'package:adaptive_mastery/core/networking/token_storage.dart';
import 'package:adaptive_mastery/core/widgets/pulse_placeholder.dart';
import 'package:adaptive_mastery/features/auth/auth_controller.dart';
import 'package:adaptive_mastery/features/auth/auth_gateway.dart';
import 'package:adaptive_mastery/features/goals/goals_controller.dart';
import 'package:adaptive_mastery/features/knowledge_graph/graph_controller.dart';
import 'package:adaptive_mastery/features/learning/learn_controller.dart';
import 'package:adaptive_mastery/features/mastery/mastery_controller.dart';
import 'package:adaptive_mastery/features/review/review_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Gateway implements AuthGateway {
  @override
  Future<String?> idToken({bool forceRefresh = false}) async => 'id-token';

  @override
  Future<void> signIn(String email, String password) async {}

  @override
  Future<void> signOut() async {}
}

void main() {
  testWidgets('trajectory shows the selected goal and next step', (tester) async {
    final auth = _signedIn();
    final goals = GoalsController()
      ..goal = {'id': 'g', 'title': 'Decision Trees', 'minutes_per_week': 180, 'status': 'active', 'graph_id': 'graph'}
      ..recommendation = {
        'step': {'concept_title': 'Entropy', 'rationale': 'priority=0.2; status=unknown', 'estimated_minutes': 12},
      };
    await tester.pumpWidget(_app(auth, goals: goals));
    await tester.tap(find.text('Trajectories'));
    await tester.pumpAndSettle();
    expect(find.text('Decision Trees'), findsOneWidget);
    expect(find.text('Entropy'), findsOneWidget);
  });

  testWidgets('graph shows nodes and opens progress', (tester) async {
    final graph = GraphController()
      ..workspace = {
        'nodes': [
          {
            'concept_id': 'dt',
            'title': 'Decision Trees',
            'summary': 'Partitions',
            'mastery_status': 'unknown',
            'estimate': 0,
            'objectives': [
              {'statement': 'explain a decision tree'},
            ],
          },
          {
            'concept_id': 'entropy',
            'title': 'Entropy',
            'summary': 'Uncertainty',
            'mastery_status': 'learning',
            'estimate': 0.4,
            'objectives': [
              {'statement': 'calculate entropy'},
            ],
          },
        ],
        'edges': [
          {'from_concept_id': 'dt', 'to_concept_id': 'entropy', 'type': 'prerequisite', 'status': 'published'},
        ],
        'trajectory_concept_ids': ['dt', 'entropy'],
      };
    await tester.pumpWidget(_app(_signedIn(), graph: graph));
    expect(find.text('Entropy'), findsOneWidget);
    expect(find.text('Unknown'), findsOneWidget);
    await tester.tap(find.text('Decision Trees'));
    await tester.pumpAndSettle();
    expect(find.text('PROGRESS'), findsOneWidget);
    expect(find.text('explain a decision tree'), findsOneWidget);
  });

  testWidgets('learn shows feedback after an answer', (tester) async {
    final learn = LearnController()
      ..activity = {
        'id': 'a',
        'body': {'prompt': 'calculate entropy from class frequencies'},
      }
      ..feedback = {
        'feedback': {'score': 0.8, 'next_hint': 'Include entropy', 'uncertain': false},
      };
    final goals = GoalsController()..goal = {'id': 'g', 'title': 'Decision Trees'};
    await tester.pumpWidget(_app(_signedIn(), goals: goals, learn: learn));
    await tester.tap(find.text('Trajectories'));
    await tester.pumpAndSettle();
    expect(find.text('Score 0.8'), findsOneWidget);
  });

  testWidgets('review shows the due prompt before reveal', (tester) async {
    final review = ReviewController()
      ..due = [
        {'id': 'r', 'prompt': 'calculate entropy from class frequencies', 'status': 'due'},
      ];
    await tester.pumpWidget(_app(_signedIn(), review: review));
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    expect(find.text('calculate entropy from class frequencies'), findsOneWidget);
    expect(find.text('Answer before you reveal'), findsOneWidget);
  });

  testWidgets('graph update panel lists kept and new skills', (tester) async {
    final graph = GraphController()
      ..tree = {
        'nodes': [
          {
            'concept_id': 'dt',
            'title': 'Decision Trees',
            'summary': 'Partitions',
            'mastery_status': 'demonstrated',
            'objectives': [],
            'prerequisites': [],
            'children': [],
          },
        ],
      }
      ..detail = {
        'concept_id': 'dt',
        'title': 'Decision Trees',
        'summary': 'Partitions',
        'objectives': [
          {'statement': 'explain a decision tree'},
        ],
      }
      ..impact = {
        'impact': {'preserved_objectives': 18, 'new_objectives': 3, 'reassessment_objectives': 1},
      };
    await tester.pumpWidget(_app(_signedIn(), graph: graph));
    expect(find.text('18 skills kept'), findsOneWidget);
    expect(find.text('3 new'), findsOneWidget);
    expect(find.text('1 needs recheck'), findsOneWidget);
  });

  testWidgets('expired session surfaces the auth error', (tester) async {
    final tokens = MemoryTokenStore()..value = 'stale';
    final api = ApiClient(baseUrl: 'http://localhost', tokens: tokens);
    final auth = AuthController(api: api, gateway: _Gateway());
    auth.error = 'Session expired';
    await tester.pumpWidget(_app(auth));
    expect(find.text('Session expired'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('loading slot uses a full-size pulse', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox(height: 120, width: 200, child: PulsePlaceholder()))));
    expect(tester.getSize(find.byType(PulsePlaceholder)), const Size(200, 120));
  });

  test('api client maps the error envelope', () {
    expect(ApiException(401, 'UNAUTHORIZED', 'Not authenticated').code, 'UNAUTHORIZED');
  });
}

AuthController _signedIn() {
  final auth = AuthController(api: ApiClient(baseUrl: 'http://localhost', tokens: MemoryTokenStore()), gateway: _Gateway());
  auth.user = UserProfile(id: '1', displayName: 'Ada', timezone: 'UTC');
  return auth;
}

Widget _app(
  AuthController auth, {
  GoalsController? goals,
  GraphController? graph,
  LearnController? learn,
  ReviewController? review,
  MasteryController? mastery,
}) {
  return AdaptiveMasteryApp(
    auth: auth,
    goals: goals ?? GoalsController(),
    graph: graph ?? GraphController(),
    learn: learn ?? LearnController(),
    review: review ?? ReviewController(),
    mastery: mastery ?? MasteryController(),
  );
}
