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

  @override
  Future<void> updateEmail(String email) async {}

  @override
  Future<void> updatePassword(String newPassword) async {}

  @override
  Future<void> reauthenticate({required String email, required String password}) async {}
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
        if (path.startsWith('/knowledge/map')) {
          return {'nodes': [], 'edges': [], 'window': {}};
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
      loader: (path) async {
        if (path.startsWith('/knowledge/map')) return _compact();
        return _compact();
      },
    )..seedForTest(graph: _compact());
    await tester.pumpWidget(_app(_signedIn(), graph));
    await tester.pumpAndSettle();

    expect(find.byWidgetPredicate(_titleLooksLike('Saurischia')), findsWidgets);
    expect(find.byWidgetPredicate(_titleLooksLike('Mammals')), findsWidgets);
    expect(find.byWidgetPredicate(_titleLooksLike('Mesozoic')), findsWidgets);
    expect(find.byWidgetPredicate(_titleLooksLike('Dinosaurs')), findsWidgets);
    expect(find.byTooltip('Search'), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('0 / 100 XP'), findsOneWidget);
  });

  testWidgets('profile hud opens overlay with settings and logout', (tester) async {
    final graph = GraphController(
      poster: (path, {body}) async => _compact(),
      loader: (path) async {
        if (path.startsWith('/knowledge/map')) return _compact();
        return _compact();
      },
    )..seedForTest(graph: _compact());
    await tester.pumpWidget(_app(_signedIn(), graph));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Logout'), findsOneWidget);
    expect(find.text('Progress'), findsOneWidget);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('App'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);
    expect(find.text('Account'), findsOneWidget);
    expect(find.text('Neighborhood size'), findsOneWidget);
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
        if (path.startsWith('/knowledge/map')) return _compact();
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
    expect(find.byWidgetPredicate(_titleLooksLike('Saurischia')), findsWidgets);
  });

  testWidgets('search fab expands a field and dismisses on outside tap', (tester) async {
    final graph = GraphController(
      poster: (path, {body}) async => _compact(),
      loader: (path) async {
        if (path.startsWith('/knowledge/map')) return _compact();
        return _compact();
      },
    )..seedForTest(graph: _compact());
    await tester.pumpWidget(_app(_signedIn(), graph));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(find.byType(FloatingActionButton), findsOneWidget);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    await tester.tapAt(const Offset(24, 180));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('panning the graph keeps search open', (tester) async {
    final graph = GraphController(
      poster: (path, {body}) async => _compact(),
      loader: (path) async {
        if (path.startsWith('/knowledge/map')) return _compact();
        return _compact();
      },
    )..seedForTest(graph: _compact());
    await tester.pumpWidget(_app(_signedIn(), graph));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    final gesture = await tester.startGesture(const Offset(200, 280));
    await gesture.moveBy(const Offset(0, -80));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('typing in search lists existing topics and opens without focus post', (tester) async {
    final posts = <Object?>[];
    final graph = GraphController(
      poster: (path, {body}) async {
        posts.add(body);
        return _compact();
      },
      loader: (path) async {
        if (path.startsWith('/knowledge/nodes')) {
          return {
            'nodes': [
              {'id': '3', 'title': 'Saurischia', 'description': 'Lizard-hipped dinosaurs.', 'q': 1, 'r': 0},
            ],
          };
        }
        if (path == '/knowledge/graph/3') return _saurischia();
        if (path.startsWith('/knowledge/map')) return _saurischia();
        return _compact();
      },
    )..seedForTest(graph: _compact());
    await tester.pumpWidget(_app(_signedIn(), graph));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'saur');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
    expect(find.text('Saurischia'), findsWidgets);
    expect(find.textContaining('Lizard-hipped'), findsOneWidget);

    await tester.tap(find.textContaining('Lizard-hipped'));
    await tester.pumpAndSettle();
    expect(graph.focusId, '3');
    expect(posts, isEmpty);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('tapping back returns to the previous focus', (tester) async {
    final graph = GraphController(
      poster: (path, {body}) async {
        final id = body is Map ? body['node_id']?.toString() : null;
        if (id == '3') return _saurischia();
        return _compact();
      },
      loader: (path) async {
        if (path.startsWith('/knowledge/map')) return _compact();
        return _compact();
      },
    )..seedForTest(graph: _saurischia())
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

  test('world layout places equal hexes from axial coords', () {
    final layout = layoutWorld(
      const [
        GraphNode(id: '1', title: 'Science', depth: 0, q: 0, r: 0),
        GraphNode(id: '2', title: 'Biology', depth: 1, q: 1, r: 0),
        GraphNode(id: '3', title: 'Zoology', depth: 2, q: 2, r: 0),
      ],
      viewport: const Size(390, 700),
    );
    final byId = {for (final node in layout.nodes) node.id: node};
    expect(byId['1']!.isFlower, isFalse);
    expect(byId['2']!.width, closeTo(byId['1']!.width, 0.01));
    expect(byId['2']!.center.dx > byId['1']!.center.dx, isTrue);
    expect(byId['3']!.center.dx > byId['2']!.center.dx, isTrue);
  });

  test('api client maps the error envelope', () {
    expect(ApiException(401, 'UNAUTHORIZED', 'Not authenticated').code, 'UNAUTHORIZED');
  });
}

/// Titles may hard-hyphenate under the test font; compare without '-' / newlines.
bool Function(Widget) _titleLooksLike(String title) {
  return (widget) {
    if (widget is! Text) return false;
    final raw = widget.data;
    if (raw == null) return false;
    return raw.replaceAll('-', '').replaceAll('\n', '') == title ||
        raw.replaceAll('-', '').replaceAll('\n', '').contains(title);
  };
}

Map<String, dynamic> _compact() {
  return {
    'focus_node_id': '2',
    'incomplete': false,
    'nodes': [
      {'id': '1', 'title': 'Reptiles', 'depth': 0, 'distance': 0, 'kind': 'parent', 'q': 0, 'r': 0},
      {
        'id': '2',
        'title': 'Dinosaurs',
        'depth': 1,
        'distance': 1,
        'kind': 'focus',
        'description': 'Extinct Mesozoic reptiles known from fossils worldwide.',
        'q': 1,
        'r': 0,
      },
      {'id': '3', 'title': 'Saurischia', 'depth': 2, 'distance': 2, 'kind': 'child', 'q': 2, 'r': 0},
      {'id': '4', 'title': 'Mammals', 'depth': 1, 'distance': 1, 'kind': 'sibling', 'q': 0, 'r': 1},
      {'id': '5', 'title': 'Mesozoic', 'depth': 1, 'distance': 1, 'kind': 'related', 'q': 1, 'r': -1},
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
      {'id': '2', 'title': 'Dinosaurs', 'depth': 1, 'distance': 1, 'kind': 'parent', 'q': 1, 'r': 0},
      {'id': '3', 'title': 'Saurischia', 'depth': 2, 'distance': 2, 'kind': 'focus', 'q': 2, 'r': 0},
      {'id': '8', 'title': 'Theropods', 'depth': 3, 'distance': 3, 'kind': 'child', 'q': 3, 'r': 0},
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
