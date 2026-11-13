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
    await tester.pumpWidget(
      AdaptiveMasteryApp(
        auth: auth,
        graph: GraphController(),
        splashHold: Duration.zero,
        showBrandedSplash: false,
      ),
    );
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
            'neighborhood': {
              'total': 16,
              'extended': 12,
            },
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

    expect(find.byWidgetPredicate(_titleLooksLike('Saurischia')), findsWidgets);
    expect(find.byWidgetPredicate(_titleLooksLike('Mammals')), findsWidgets);
    expect(find.byWidgetPredicate(_titleLooksLike('Mesozoic')), findsWidgets);
    expect(find.textContaining('Extinct Mesozoic reptiles'), findsWidgets);
    expect(find.byTooltip('Search'), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('0 / 100 XP'), findsOneWidget);
  });

  testWidgets('profile hud opens overlay with settings and logout', (tester) async {
    final graph = GraphController(
      poster: (path, {body}) async => _compact(),
      loader: (path) async => _compact(),
    )..categoryGraph = _compact();
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

  testWidgets('job queue tracks expands without blocking navigation', (tester) async {
    var polls = 0;
    late final GraphController graph;
    graph = GraphController(
      loader: (path) async {
        if (path == '/me/preferences') {
          return {
            'neighborhood': {
              'total': 16,
              'extended': 12,
            },
          };
        }
        if (path == '/jobs?state=queued,running') {
          return {
            'jobs': [
              for (final j in graph.trackedJobs)
                {
                  'id': j.jobId,
                  'focus_node_id': j.nodeId,
                  'title': j.title,
                  'state': j.state,
                  'progress': {'message': j.progressMessage, 'fraction': j.fraction},
                },
            ],
          };
        }
        if (path.startsWith('/knowledge/graph/')) return _compact();
        return {'focus_node_id': null, 'nodes': [], 'edges': []};
      },
      poster: (path, {body}) async {
        final map = body is Map ? body : const <String, dynamic>{};
        final expand = map['expand'] == true;
        final topic = map['topic']?.toString();
        final nodeId = map['node_id']?.toString();
        if (!expand) {
          if ((topic == null || topic.isEmpty) && (nodeId == null || nodeId.isEmpty)) {
            return {'focus_node_id': null, 'incomplete': false, 'nodes': [], 'edges': []};
          }
          return {
            'focus_node_id': nodeId ?? '2',
            'incomplete': true,
            'nodes': [
              {'id': nodeId ?? '2', 'title': topic ?? 'Dinosaurs', 'kind': 'focus'},
            ],
            'edges': <Map<String, dynamic>>[],
          };
        }
        return {
          'status': 'queued',
          'job_id': 'job-1',
          'focus_node_id': nodeId ?? '2',
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
    await graph.search('dinosaurs');
    await tester.pumpAndSettle();
    expect(graph.focusId, '2');
    expect(graph.categoryGraph?['incomplete'], isTrue);
    expect(graph.activeJobCount, 0);

    final pending = graph.enqueueNeighborhood('2', title: 'Dinosaurs');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(graph.activeJobCount, 1);
    expect(graph.trackedJobs.first.jobId, 'job-1');
    expect(find.byTooltip('Show running jobs'), findsOneWidget);
    // Search stays available while a job is tracked.
    expect(find.byTooltip('Search'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await pending;
    await tester.pumpAndSettle();
    expect(graph.focusId, '2');
    expect(graph.activeJobCount, 0);
    expect(find.byWidgetPredicate(_titleLooksLike('Saurischia')), findsWidgets);
  });

  testWidgets('incomplete focus shows request FAB and does not auto-enqueue on open', (tester) async {
    var posts = 0;
    Map<String, dynamic>? lastBody;
    final graph = GraphController(
      poster: (path, {body}) async {
        posts += 1;
        lastBody = body is Map ? Map<String, dynamic>.from(body) : null;
        return {
          'status': 'queued',
          'job_id': 'job-req',
          'focus_node_id': '2',
          'progress': {'message': 'Asking the model…'},
        };
      },
      jobLoader: (jobId) async => {
            'id': jobId,
            'state': 'running',
            'progress': {'message': 'Asking the model…'},
          },
      loader: (path) async => _compactIncomplete(),
    )..categoryGraph = _compactIncomplete();
    await tester.pumpWidget(_app(_signedIn(), graph));
    await tester.pumpAndSettle();

    expect(posts, 0);
    expect(find.byTooltip('Request neighbors'), findsOneWidget);
    expect(find.text('Parents'), findsNothing);

    await tester.tap(find.byTooltip('Request neighbors'));
    await tester.pump();
    expect(posts, 1);
    expect(lastBody?['expand'], isTrue);
    expect(graph.activeJobCount, 1);
    expect(find.byTooltip('Show running jobs'), findsOneWidget);
    graph.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('opening incomplete tile loads neighbors without posting expand', (tester) async {
    var posts = 0;
    final gets = <String>[];
    final graph = GraphController(
      poster: (path, {body}) async {
        posts += 1;
        return {};
      },
      loader: (path) async {
        gets.add(path);
        if (path.startsWith('/knowledge/graph/1')) {
          return {
            'focus_node_id': '1',
            'incomplete': true,
            'nodes': [
              {'id': '1', 'title': 'Reptiles', 'kind': 'focus'},
            ],
            'edges': <Map<String, dynamic>>[],
          };
        }
        return _compact();
      },
    )..categoryGraph = _compact();
    await tester.pumpWidget(_app(_signedIn(), graph));
    await tester.pumpAndSettle();

    // Same sequence as dwell / drawer open: GET neighborhood, then adopt it.
    final payload = await graph.fetchGraph('1');
    expect(payload?['incomplete'], isTrue);
    await graph.openExisting('1', title: 'Reptiles', knownPayload: payload);
    await tester.pumpAndSettle();

    expect(posts, 0);
    expect(graph.focusId, '1');
    expect(gets.any((path) => path.startsWith('/knowledge/graph/1')), isTrue);
    expect(find.byTooltip('Request neighbors'), findsOneWidget);
  });

  test('openExisting does not enqueue when incomplete', () async {
    var posts = 0;
    final graph = GraphController(
      poster: (path, {body}) async {
        posts += 1;
        return {};
      },
      loader: (path) async => _compactIncomplete(),
    );
    await graph.openExisting('2');
    expect(posts, 0);
    expect(graph.categoryGraph?['incomplete'], isTrue);
    expect(graph.activeJobCount, 0);
  });

  testWidgets('search fab expands a field and dismisses on outside tap', (tester) async {
    final graph = GraphController(
      poster: (path, {body}) async => _compact(),
      loader: (path) async => _compact(),
    )..categoryGraph = _compact();
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
      loader: (path) async => _compact(),
    )..categoryGraph = _compact();
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
              {'id': '3', 'title': 'Saurischia', 'description': 'Lizard-hipped dinosaurs.'},
            ],
          };
        }
        if (path == '/knowledge/graph/3') return _saurischia();
        return _compact();
      },
    )..categoryGraph = _compact();
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
        GraphNode(id: '5', title: 'Mesozoic', depth: 0, kind: 'related'),
      ],
      const [],
      focusId: '2',
      viewport: const Size(390, 700),
    );
    final byId = {for (final node in layout.nodes) node.id: node};
    final focus = byId['2']!;
    expect(byId['1']!.center.dy < focus.center.dy, isTrue);
    expect(focus.center.dy < byId['3']!.center.dy, isTrue);
    expect((byId['4']!.center.dx - focus.center.dx).abs(), greaterThan((byId['4']!.center.dy - focus.center.dy).abs()));
    expect(byId['4']!.role, NodeRole.sibling);
    expect(byId['2']!.isFlower, isTrue);
    // 7-hex flower spans ~2.5× a unit hex width.
    expect(byId['2']!.width / byId['4']!.width, closeTo(2.5, 0.15));
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

Map<String, dynamic> _compactIncomplete() {
  final graph = _compact();
  graph['incomplete'] = true;
  return graph;
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
  return AdaptiveMasteryApp(
    auth: auth,
    graph: graph,
    splashHold: Duration.zero,
    showBrandedSplash: false,
  );
}
