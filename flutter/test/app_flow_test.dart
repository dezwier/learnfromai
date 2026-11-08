import 'package:adaptive_mastery/app.dart';
import 'package:adaptive_mastery/core/networking/api_client.dart';
import 'package:adaptive_mastery/core/networking/api_exception.dart';
import 'package:adaptive_mastery/core/networking/token_storage.dart';
import 'package:adaptive_mastery/core/widgets/pulse_placeholder.dart';
import 'package:adaptive_mastery/features/auth/auth_controller.dart';
import 'package:adaptive_mastery/features/auth/auth_gateway.dart';
import 'package:adaptive_mastery/features/knowledge_graph/graph_controller.dart';
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
  testWidgets('signed out users see sign in', (tester) async {
    final tokens = MemoryTokenStore();
    final api = ApiClient(baseUrl: 'http://localhost', tokens: tokens);
    final auth = AuthController(api: api, gateway: _Gateway());
    await tester.pumpWidget(AdaptiveMasteryApp(auth: auth, graph: GraphController()));
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsWidgets);
    expect(find.text('Trajectories'), findsNothing);
    expect(find.text('Review'), findsNothing);
  });

  testWidgets('graph shows nodes, summary, and solid extend history', (tester) async {
    final graph = GraphController()
      ..workspace = {
        'nodes': [
          {'concept_id': 'dt', 'title': 'Decision Trees', 'summary': 'Partitions'},
          {'concept_id': 'entropy', 'title': 'Entropy', 'summary': 'Uncertainty'},
        ],
        'edges': [
          {'edge_id': 'e1', 'from_concept_id': 'dt', 'to_concept_id': 'entropy', 'type': 'prerequisite'},
        ],
        'extend_requests': [
          {'id': 'r1', 'instruction': 'Add dinosaurs', 'status': 'succeeded', 'author': 'Ada', 'created_at': '2026-11-08T04:00:00Z'},
        ],
      };
    await tester.pumpWidget(_app(_signedIn(), graph));
    await tester.pumpAndSettle();
    expect(find.text('Entropy'), findsOneWidget);
    expect(find.text('Decision Trees'), findsOneWidget);
    expect(find.text('Trajectories'), findsNothing);
    expect(find.text('Accept change'), findsNothing);
    expect(find.byType(CustomPaint), findsWidgets);

    await tester.tap(find.byTooltip('Past extends'));
    await tester.pumpAndSettle();
    expect(find.text('Add dinosaurs'), findsOneWidget);
    expect(find.textContaining('Ada'), findsWidgets);
    await tester.tapAt(const Offset(20, 40));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Decision Trees'));
    await tester.pumpAndSettle();
    expect(find.text('Partitions'), findsOneWidget);
    expect(find.text('Extend this node'), findsOneWidget);
    expect(find.text('Delete node'), findsOneWidget);

    await tester.tap(find.text('Delete node'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Decision Trees?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Decision Trees'), findsWidgets);

    await tester.tap(find.text('Delete node'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Extend this node'), findsNothing);
    expect(find.text('Decision Trees'), findsOneWidget);
  });

  testWidgets('expired session surfaces the auth error', (tester) async {
    final tokens = MemoryTokenStore()..value = 'stale';
    final api = ApiClient(baseUrl: 'http://localhost', tokens: tokens);
    final auth = AuthController(api: api, gateway: _Gateway());
    auth.error = 'Session expired';
    await tester.pumpWidget(AdaptiveMasteryApp(auth: auth, graph: GraphController()));
    await tester.pumpAndSettle();
    expect(find.text('Session expired'), findsOneWidget);
    expect(find.text('Sign in'), findsWidgets);
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

Widget _app(AuthController auth, GraphController graph) {
  return AdaptiveMasteryApp(auth: auth, graph: graph);
}
