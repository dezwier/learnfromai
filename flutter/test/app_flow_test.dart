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

  testWidgets('an empty graph asks for a topic', (tester) async {
    final graph = GraphController(
      loader: (path) async {
        expect(path, startsWith('/knowledge/graph'));
        return {'focus_node_id': null, 'incomplete': false, 'nodes': [], 'edges': []};
      },
    );
    await tester.pumpWidget(_app(_signedIn(), graph));
    await tester.pumpAndSettle();
    expect(find.text('Explore the graph'), findsOneWidget);
    expect(find.text('Extend the graph'), findsNothing);
    expect(find.byTooltip('Past extends'), findsNothing);
  });

  testWidgets('the hex map shows children of the focus', (tester) async {
    final graph = GraphController(
      loader: (path) async => _compact(),
    )..categoryGraph = _compact();
    await tester.pumpWidget(_app(_signedIn(), graph));
    await tester.pumpAndSettle();

    expect(find.text('Saurischia'), findsOneWidget);
    expect(find.text('Show more'), findsNothing);
  });

  testWidgets('tapping a category focuses it and back returns', (tester) async {
    final graph = GraphController(
      loader: (path) async {
        if (path.contains('category_id=3')) return _saurischia();
        if (path.contains('category_id=2')) return _compact();
        return _compact();
      },
    )
      ..categoryGraph = _saurischia()
      ..focusHistory.addAll([2, 3]);
    await tester.pumpWidget(_app(_signedIn(), graph));
    await tester.pumpAndSettle();

    expect(graph.focusId, 3);
    expect(find.text('Genera'), findsOneWidget);
    expect(find.byTooltip('Previous topic'), findsOneWidget);

    await tester.tap(find.byTooltip('Previous topic'));
    await tester.pumpAndSettle();
    expect(graph.focusId, 2);
    expect(find.text('Saurischia'), findsOneWidget);
  });

  testWidgets('ambiguous results can be chosen', (tester) async {
    final graph = GraphController(
      loader: (path) async {
        expect(path, contains('category_id=6'));
        return _compact();
      },
    )..candidates = const [
        CategoryChoice(id: 6, title: 'Dinosaur toys'),
        CategoryChoice(id: 10, title: 'Dinosaur colors'),
      ];
    await tester.pumpWidget(_app(_signedIn(), graph));
    await tester.pumpAndSettle();
    expect(find.text('Choose a topic'), findsOneWidget);
    expect(find.text('Dinosaur toys'), findsOneWidget);

    await tester.tap(find.text('Dinosaur toys'));
    await tester.pumpAndSettle();
    expect(graph.focusId, 2);
    expect(find.text('Saurischia'), findsOneWidget);
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
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SizedBox(height: 120, width: 200, child: PulsePlaceholder())),
      ),
    );
    expect(tester.getSize(find.byType(PulsePlaceholder)), const Size(200, 120));
  });

  test('api client maps the error envelope', () {
    expect(ApiException(401, 'UNAUTHORIZED', 'Not authenticated').code, 'UNAUTHORIZED');
  });
}

Map<String, dynamic> _dinosaurs() {
  return {
    'focus_node_id': 2,
    'incomplete': false,
    'nodes': [
      {'id': 1, 'title': 'Paleontology', 'depth': -1},
      {'id': 2, 'title': 'Dinosaurs', 'depth': 0},
        {'id': 3, 'title': 'Saurischia', 'depth': 1},
      for (var index = 0; index < 5; index++) {'id': 20 + index, 'title': 'Child $index', 'depth': 1},
      {'id': 30, 'title': 'Zebra', 'depth': 1},
    ],
    'edges': [
      {'source': 1, 'target': 2, 'type': 'parent_child'},
      {'source': 2, 'target': 3, 'type': 'parent_child'},
      for (var index = 0; index < 5; index++) {'source': 2, 'target': 20 + index, 'type': 'parent_child'},
      {'source': 2, 'target': 30, 'type': 'parent_child'},
    ],
  };
}

Map<String, dynamic> _compact() {
  return {
    'focus_node_id': 2,
    'incomplete': false,
    'nodes': [
      {'id': 1, 'title': 'Paleontology', 'depth': -1},
      {'id': 2, 'title': 'Dinosaurs', 'depth': 0},
      {'id': 3, 'title': 'Saurischia', 'depth': 1},
    ],
    'edges': [
      {'source': 1, 'target': 2, 'type': 'parent_child'},
      {'source': 2, 'target': 3, 'type': 'parent_child'},
    ],
  };
}

Map<String, dynamic> _saurischia() {
  return {
    'focus_node_id': 3,
    'incomplete': false,
    'nodes': [
      {'id': 2, 'title': 'Dinosaurs', 'depth': -1},
      {'id': 3, 'title': 'Saurischia', 'depth': 0},
      {'id': 8, 'title': 'Genera', 'depth': 1},
    ],
    'edges': [
      {'source': 2, 'target': 3, 'type': 'parent_child'},
      {'source': 3, 'target': 8, 'type': 'parent_child'},
    ],
  };
}

AuthController _signedIn() {
  final auth = AuthController(
    api: ApiClient(baseUrl: 'http://localhost', tokens: MemoryTokenStore()),
    gateway: _Gateway(),
  );
  auth.user = UserProfile(id: '1', displayName: 'Ada', timezone: 'UTC');
  return auth;
}

Widget _app(AuthController auth, GraphController graph) {
  return AdaptiveMasteryApp(auth: auth, graph: graph);
}
