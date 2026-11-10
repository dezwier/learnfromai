import 'package:adaptive_mastery/app.dart';
import 'package:adaptive_mastery/core/networking/api_client.dart';
import 'package:adaptive_mastery/core/networking/api_exception.dart';
import 'package:adaptive_mastery/core/networking/token_storage.dart';
import 'package:adaptive_mastery/core/widgets/pulse_placeholder.dart';
import 'package:adaptive_mastery/features/auth/auth_controller.dart';
import 'package:adaptive_mastery/features/auth/auth_gateway.dart';
import 'package:adaptive_mastery/features/knowledge_graph/graph_controller.dart';
import 'package:adaptive_mastery/features/knowledge_graph/graph_layout.dart';
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
  });

  testWidgets('an empty graph asks for a topic', (tester) async {
    final graph = GraphController(
      poster: (path, {body}) async {
        expect(path, '/knowledge/focus');
        return {'focus_node_id': null, 'incomplete': false, 'nodes': [], 'edges': []};
      },
      loader: (path) async {
        if (path == '/me/preferences') {
          return {
            'neighborhood': {'parents': 2, 'siblings': 3, 'children': 4, 'acquaintances': 4},
          };
        }
        return {'focus_node_id': null, 'incomplete': false, 'nodes': [], 'edges': []};
      },
    );
    await tester.pumpWidget(_app(_signedIn(), graph));
    await tester.pumpAndSettle();
    expect(find.text('Explore the graph'), findsOneWidget);
  });

  testWidgets('graph shows parents, siblings, children, related', (tester) async {
    final graph = GraphController(
      poster: (path, {body}) async => _compact(),
      loader: (path) async => _compact(),
    )..categoryGraph = _compact();
    await tester.pumpWidget(_app(_signedIn(), graph));
    await tester.pumpAndSettle();

    expect(find.text('Saurischia'), findsOneWidget);
    expect(find.text('Mammals'), findsOneWidget);
    expect(find.text('Mesozoic'), findsOneWidget);
    expect(find.textContaining('Extinct Mesozoic reptiles'), findsOneWidget);
    expect(find.byTooltip('Search'), findsOneWidget);
  });

  testWidgets('job progress barrier appears while generating', (tester) async {
    var polls = 0;
    final graph = GraphController(
      loader: (path) async {
        if (path == '/me/preferences') {
          return {
            'neighborhood': {'parents': 2, 'siblings': 3, 'children': 4, 'acquaintances': 4},
          };
        }
        if (path.startsWith('/knowledge/graph/')) return _compact();
        return {'focus_node_id': null, 'nodes': [], 'edges': []};
      },
      poster: (path, {body}) async {
        final topic = body is Map ? body['topic']?.toString() : null;
        if (topic == null || topic.isEmpty) {
          return {'focus_node_id': null, 'nodes': [], 'edges': []};
        }
        return {
          'status': 'queued',
          'job_id': 'job-1',
          'focus_node_id': '2',
          'progress': {'message': 'Asking the model…'},
        };
      },
      jobLoader: (jobId) async {
        polls += 1;
        if (polls < 2) {
          return {
            'id': jobId,
            'state': 'running',
            'progress': {'message': 'Merging Reptiles…'},
          };
        }
        return {
          'id': jobId,
          'state': 'succeeded',
          'progress': {'message': 'Neighborhood ready'},
          'result': {'focus_id': '2'},
        };
      },
    );
    await tester.pumpWidget(_app(_signedIn(), graph));
    await tester.pumpAndSettle();
    final pending = graph.search('dinosaurs');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(graph.working, isTrue);
    expect(find.textContaining('Merging Reptiles'), findsOneWidget);
    // Progress is a non-blocking lower-left chip, not a full-screen barrier.
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    await tester.pump(const Duration(milliseconds: 800));
    await pending;
    await tester.pumpAndSettle();
    expect(graph.focusId, '2');
    expect(find.text('Saurischia'), findsOneWidget);
  });

  testWidgets('search fab expands a field and dismisses on outside tap', (tester) async {
    final graph = GraphController(
      poster: (path, {body}) async => _compact(),
      loader: (path) async => _compact(),
    )..categoryGraph = _compact();
    await tester.pumpWidget(_app(_signedIn(), graph));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    await tester.tapAt(const Offset(24, 180));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('tapping back returns to the previous focus', (tester) async {
    final graph = GraphController(
      poster: (path, {body}) async {
        final id = body is Map ? body['node_id']?.toString() : null;
        if (id == '3') return _saurischia();
        return _compact();
      },
      loader: (path) async => _compact(),
    )
      ..categoryGraph = _saurischia()
      ..focusHistory.addAll(['2', '3']);
    await tester.pumpWidget(_app(_signedIn(), graph));
    await tester.pumpAndSettle();

    expect(graph.focusId, '3');
    await tester.tap(find.byTooltip('Previous topic'));
    await tester.pumpAndSettle();
    expect(graph.focusId, '2');
  });

  testWidgets('loading slot uses a full-size pulse', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SizedBox(height: 120, width: 200, child: PulsePlaceholder())),
      ),
    );
    expect(tester.getSize(find.byType(PulsePlaceholder)), const Size(200, 120));
  });

  test('graph places parents above, siblings beside, children below', () {
    final layout = layoutGraph(
      const [
        GraphNode(id: '1', title: 'Reptile', depth: -1, kind: 'parent'),
        GraphNode(id: '2', title: 'Dinosaur', depth: 0, kind: 'focus'),
        GraphNode(id: '3', title: 'Saurischia', depth: 1, kind: 'child'),
        GraphNode(id: '4', title: 'Mammals', depth: 0, kind: 'sibling'),
      ],
      const [],
      focusId: '2',
      viewport: const Size(390, 700),
    );
    final byId = {for (final node in layout.nodes) node.id: node};
    expect(byId['1']!.center.dy < byId['2']!.center.dy, isTrue);
    expect(byId['2']!.center.dy < byId['3']!.center.dy, isTrue);
    expect(byId['4']!.role, NodeRole.sibling);
    expect(byId['2']!.isFlower, isTrue);
    expect(byId['2']!.width / byId['4']!.width, closeTo(2.5, 0.05));
  });

  test('api client maps the error envelope', () {
    expect(ApiException(401, 'UNAUTHORIZED', 'Not authenticated').code, 'UNAUTHORIZED');
  });
}

Map<String, dynamic> _compact() {
  return {
    'focus_node_id': '2',
    'incomplete': false,
    'nodes': [
      {'id': '1', 'title': 'Reptiles', 'depth': -1, 'distance': 1, 'kind': 'parent'},
      {
        'id': '2',
        'title': 'Dinosaurs',
        'depth': 0,
        'distance': 0,
        'kind': 'focus',
        'description': 'Extinct Mesozoic reptiles known from fossils worldwide.',
      },
      {'id': '3', 'title': 'Saurischia', 'depth': 1, 'distance': 1, 'kind': 'child'},
      {'id': '4', 'title': 'Mammals', 'depth': 0, 'distance': 1, 'kind': 'sibling'},
      {'id': '5', 'title': 'Mesozoic', 'depth': 0, 'distance': 1, 'kind': 'related'},
    ],
    'edges': [
      {'source': '2', 'target': '1', 'type': 'parent'},
      {'source': '2', 'target': '3', 'type': 'child'},
      {'source': '2', 'target': '4', 'type': 'sibling'},
      {'source': '2', 'target': '5', 'type': 'acquaintance'},
    ],
  };
}

Map<String, dynamic> _saurischia() {
  return {
    'focus_node_id': '3',
    'incomplete': false,
    'nodes': [
      {'id': '2', 'title': 'Dinosaurs', 'depth': -1, 'distance': 1, 'kind': 'parent'},
      {'id': '3', 'title': 'Saurischia', 'depth': 0, 'distance': 0, 'kind': 'focus'},
      {'id': '8', 'title': 'Theropods', 'depth': 1, 'distance': 1, 'kind': 'child'},
    ],
    'edges': [
      {'source': '3', 'target': '2', 'type': 'parent'},
      {'source': '3', 'target': '8', 'type': 'child'},
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
