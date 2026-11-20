import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/pulse_placeholder.dart';
import '../../profile/profile_hud.dart';
import '../graph_controller.dart';
import '../models.dart';
import 'learn_card.dart';
import 'learn_edge_dismiss.dart';

const _checkKinds = ['check1', 'check2', 'check3'];

Future<void> showLearningTrack(
  BuildContext context, {
  required String seedNodeId,
  required String seedTitle,
  required String openSource,
}) {
  return Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierDismissible: true,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (context, animation, secondaryAnimation) {
        return LearningTrackSheet(
          seedNodeId: seedNodeId,
          seedTitle: seedTitle,
          openSource: openSource,
        );
      },
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        if (animation.status == AnimationStatus.reverse) return child;
        final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return FadeTransition(opacity: curved, child: child);
      },
    ),
  );
}

class LearningTrackSheet extends StatefulWidget {
  const LearningTrackSheet({
    super.key,
    required this.seedNodeId,
    required this.seedTitle,
    required this.openSource,
  });

  final String seedNodeId;
  final String seedTitle;
  final String openSource;

  @override
  State<LearningTrackSheet> createState() => _LearningTrackSheetState();
}

class _LearningTrackSheetState extends State<LearningTrackSheet> {
  final _rng = math.Random();
  final Set<String> _trackedKinds = {};
  GraphController? _graph;
  var _listening = false;
  String? _watchedJobId;
  String? _generateNodeId;
  var _loading = true;
  var _advancing = false;
  var _quizDone = false;
  var _dismissing = false;
  String? _error;
  String? _topicTitle;
  String? _nodeId;
  LearnDeckEntry? _entry;
  int _cardEpoch = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_loadNext(widget.seedNodeId, titleHint: widget.seedTitle, trackOpen: true));
    });
  }

  void _listen(GraphController graph) {
    if (_listening) return;
    _graph = graph;
    graph.addListener(_onGraphChanged);
    _listening = true;
  }

  void _stopListening() {
    if (!_listening) return;
    _graph?.removeListener(_onGraphChanged);
    _listening = false;
  }

  @override
  void dispose() {
    _stopListening();
    super.dispose();
  }

  String _trackKey(int packIndex, String kind) => '$packIndex:$kind';

  Future<void> _loadNext(
    String seedId, {
    String? titleHint,
    bool trackOpen = false,
  }) async {
    final graph = context.read<GraphController>();
    _graph = graph;
    setState(() {
      _loading = true;
      _error = null;
      _quizDone = false;
      _entry = null;
    });
    final next = await graph.fetchLearningNext(seedId);
    if (!mounted) return;
    if (next == null) {
      setState(() {
        _loading = false;
        _error = graph.error ?? 'Could not load the next learning card';
      });
      return;
    }
    if (next.needsGenerate) {
      await _startGenerate(graph, next.nodeId, next.title.isEmpty ? (titleHint ?? '') : next.title);
      return;
    }
    _applyReady(graph, next, trackOpen: trackOpen);
  }

  Future<void> _startGenerate(GraphController graph, String nodeId, String title) async {
    setState(() {
      _loading = true;
      _generateNodeId = nodeId;
      _topicTitle = title;
      _nodeId = nodeId;
      _error = null;
    });
    final queued = await graph.enqueueContent(nodeId, title: title);
    if (!mounted) return;
    if (queued == null && graph.jobForNode(nodeId, type: 'expand_content') == null) {
      setState(() {
        _loading = false;
        _error = graph.error ?? 'Could not start content generation';
      });
      return;
    }
    final job = graph.jobForNode(nodeId, type: 'expand_content');
    if (job != null) {
      _watchedJobId = job.jobId;
      _listen(graph);
      setState(() {});
      return;
    }
    // Content returned inline — pick next again.
    await _loadNext(nodeId, titleHint: title);
  }

  void _applyReady(GraphController graph, LearningNext next, {bool trackOpen = false}) {
    final pack = next.pack;
    if (pack == null) {
      setState(() {
        _loading = false;
        _error = 'No learning pack available';
      });
      return;
    }
    final available = [
      for (final kind in _checkKinds)
        if (pack.bit(kind) != null) kind,
    ];
    if (available.isEmpty) {
      setState(() {
        _loading = false;
        _error = 'Pack has no quiz';
      });
      return;
    }
    final kind = available[_rng.nextInt(available.length)];
    setState(() {
      _nodeId = next.nodeId;
      _topicTitle = next.title;
      _entry = LearnDeckEntry(pack: pack, checkKind: kind);
      _trackedKinds.clear();
      _quizDone = false;
      _loading = false;
      _error = null;
      _generateNodeId = null;
      _cardEpoch += 1;
    });
    if (trackOpen) {
      unawaited(
        graph.trackEvent(
          nodeId: next.nodeId,
          kind: 'open',
          payload: {'source': widget.openSource},
        ),
      );
    }
  }

  void _onGraphChanged() {
    if (!mounted) return;
    final graph = _graph ?? context.read<GraphController>();
    final genId = _generateNodeId;
    if (genId == null) return;
    final active = graph.jobForNode(genId, type: 'expand_content');
    if (active != null) {
      _watchedJobId = active.jobId;
      setState(() {});
      return;
    }
    if (_watchedJobId == null && graph.lastCompletedNodeId != genId) return;
    _stopListening();
    _watchedJobId = null;
    unawaited(_loadNext(genId, titleHint: _topicTitle));
  }

  void _dismiss() {
    if (_dismissing || !mounted) return;
    _dismissing = true;
    Navigator.of(context).pop();
  }

  void _trackLearn(GraphController graph, LearnDeckEntry entry) {
    final nodeId = _nodeId;
    if (nodeId == null) return;
    final key = _trackKey(entry.packIndex, 'learn');
    if (_trackedKinds.contains(key)) return;
    if (entry.pack.bit('learn') == null) return;
    _trackedKinds.add(key);
    unawaited(
      graph.trackEvent(
        nodeId: nodeId,
        kind: 'learn',
        payload: {'pack_index': entry.packIndex},
      ),
    );
  }

  void _trackCheck(
    GraphController graph,
    LearnDeckEntry entry, {
    required bool correct,
    int? choiceIndex,
    bool? answerBool,
    String? answerText,
  }) {
    final nodeId = _nodeId;
    if (nodeId == null) return;
    final key = _trackKey(entry.packIndex, entry.checkKind);
    if (_trackedKinds.contains(key)) return;
    if (entry.pack.bit(entry.checkKind) == null) return;
    _trackedKinds.add(key);
    unawaited(
      graph.trackEvent(
        nodeId: nodeId,
        kind: entry.checkKind,
        payload: {
          'pack_index': entry.packIndex,
          'correct': correct,
          if (choiceIndex != null) 'choice_index': choiceIndex,
          if (answerBool != null) 'answer_bool': answerBool,
          if (answerText != null) 'answer_text': answerText,
        },
      ),
    );
    setState(() => _quizDone = true);
  }

  Future<void> _onNext() async {
    if (_advancing || !_quizDone) return;
    final seed = _nodeId;
    if (seed == null) return;
    setState(() => _advancing = true);
    await _loadNext(seed, titleHint: _topicTitle);
    if (mounted) setState(() => _advancing = false);
  }

  (String?, String?) _imageUrls(GraphController graph, String? nodeId) {
    if (nodeId == null) return (null, null);
    final nodes = graph.categoryGraph?['nodes'];
    if (nodes is! List) return (null, null);
    for (final raw in nodes) {
      if (raw is Map && raw['id']?.toString() == nodeId) {
        final url = raw['image_url']?.toString().trim();
        final thumb = raw['image_thumb_url']?.toString().trim();
        return (
          (url == null || url.isEmpty) ? null : url,
          (thumb == null || thumb.isEmpty) ? null : thumb,
        );
      }
    }
    return (null, null);
  }

  @override
  Widget build(BuildContext context) {
    final graph = context.watch<GraphController>();
    final scheme = Theme.of(context).colorScheme;
    final padding = MediaQuery.paddingOf(context);
    final urls = _imageUrls(graph, _nodeId);
    final imageUrl = urls.$1 ?? urls.$2;
    final entry = _entry;
    final generating = _generateNodeId != null &&
        (graph.jobForNode(_generateNodeId!, type: 'expand_content') != null ||
            entry == null);
    final bottomFadeHeight = padding.bottom + 88 + ProfileTopFade.fadeExtension;

    final Widget cardBody;
    if (_loading || generating || entry == null) {
      cardBody = const SizedBox(
        height: 320,
        child: PulsePlaceholder.image(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
      );
    } else {
      cardBody = LearnFlipCard(
        key: ValueKey('track-$_cardEpoch-${entry.packIndex}-${entry.checkKind}'),
        entry: entry,
        imageUrl: imageUrl,
        imageLoading: graph.isJobTypeActive(_nodeId ?? '', 'generate_image'),
        loadImageBytes: (url) => graph.fetchImageBytes(url, notify: false),
        cachedBytes: graph.cachedImageBytes(imageUrl),
        onShown: () => _trackLearn(graph, entry),
        onCheckAnswer: ({
          required bool correct,
          int? choiceIndex,
          bool? answerBool,
          String? answerText,
        }) {
          _trackCheck(
            graph,
            entry,
            correct: correct,
            choiceIndex: choiceIndex,
            answerBool: answerBool,
            answerText: answerText,
          );
        },
      );
    }

    return Material(
      type: MaterialType.transparency,
      child: LearnEdgeSwipeToDismiss(
        onDismiss: _dismiss,
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  padding.top + 12,
                  20,
                  padding.bottom + (_quizDone ? 88 : 24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if ((_topicTitle ?? '').trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                          _topicTitle!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                            shadows: const [Shadow(blurRadius: 6, color: Colors.black45)],
                          ),
                        ),
                      ),
                    Expanded(
                      child: SingleChildScrollView(
                        child: cardBody,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: ProfileTopFade.height(context),
              child: const ProfileTopFade(),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: bottomFadeHeight,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        scheme.surface.withValues(alpha: 0.94),
                        scheme.surface.withValues(alpha: 0.72),
                        scheme.surface.withValues(alpha: 0.28),
                        scheme.surface.withValues(alpha: 0.0),
                      ],
                      stops: const [0.0, 0.35, 0.72, 1.0],
                    ),
                  ),
                ),
              ),
            ),
            if (_quizDone && entry != null)
              Positioned(
                left: 20,
                right: 20,
                bottom: padding.bottom + 16,
                child: FilledButton(
                  onPressed: _advancing ? null : () => unawaited(_onNext()),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                  child: Text(_advancing ? 'Loading…' : 'Next'),
                ),
              ),
            if (_error != null)
              Positioned(
                left: 20,
                right: 20,
                top: padding.top + 8,
                child: IgnorePointer(
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: scheme.error,
                      height: 1.35,
                      shadows: const [Shadow(blurRadius: 6, color: Colors.black45)],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
