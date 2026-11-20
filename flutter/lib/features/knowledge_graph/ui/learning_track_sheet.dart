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
import 'learning_track_support.dart';

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
  LearningTrackSupport? _support;
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
  String? _cardImageUrl;
  LearnDeckEntry? _entry;
  int _cardEpoch = 0;

  LearningTrackSupport _supportFor(GraphController graph) {
    final existing = _support;
    if (existing != null && identical(_graph, graph)) return existing;
    _graph = graph;
    final next = LearningTrackSupport(graph);
    _support = next;
    return next;
  }

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
    _support?.cancelPrefetch();
    _stopListening();
    super.dispose();
  }

  String _trackKey(int packIndex, String kind) => '$packIndex:$kind';

  Future<void> _setCardImage(LearningNext next) async {
    final support = _support;
    if (support == null) return;
    final url = await support.resolveImageUrl(next);
    if (!mounted) return;
    setState(() => _cardImageUrl = url);
  }

  Future<void> _loadNext(
    String seedId, {
    String? titleHint,
    bool trackOpen = false,
  }) async {
    final graph = context.read<GraphController>();
    final support = _supportFor(graph);
    support.cancelPrefetch();
    setState(() {
      _loading = true;
      _error = null;
      _quizDone = false;
      _entry = null;
      _cardImageUrl = null;
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
    final support = _supportFor(graph);
    support.cancelPrefetch();
    setState(() {
      _loading = true;
      _generateNodeId = nodeId;
      _topicTitle = title;
      _nodeId = nodeId;
      _cardImageUrl = null;
      _error = null;
    });
    unawaited(_setCardImage(LearningNext(status: 'generate', nodeId: nodeId, title: title)));
    final queued = await graph.enqueueContentForTrack(nodeId, title: title);
    if (!mounted) return;
    final job = graph.jobForNode(nodeId, type: 'expand_content');
    if (job != null) {
      _watchedJobId = job.jobId;
      _listen(graph);
      setState(() {});
      return;
    }
    if (queued == null) {
      setState(() {
        _generateNodeId = null;
        _loading = false;
        _error = graph.error ?? 'Could not start content generation';
      });
      return;
    }
    // 200 with existing content — try once more; do not loop generate forever.
    final next = await graph.fetchLearningNext(nodeId);
    if (!mounted) return;
    if (next != null && next.isReady) {
      _applyReady(graph, next);
      return;
    }
    setState(() {
      _generateNodeId = null;
      _loading = false;
      _error = 'No new learning pack could be started for $title';
    });
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
    final support = _supportFor(graph);
    final graphUrls = LearningTrackSupport.imageUrlsFromGraph(graph, next.nodeId);
    setState(() {
      _nodeId = next.nodeId;
      _topicTitle = next.title;
      _cardImageUrl = next.bestImageUrl ?? graphUrls.$1 ?? graphUrls.$2;
      _entry = LearnDeckEntry(pack: pack, checkKind: kind);
      _trackedKinds.clear();
      _quizDone = false;
      _loading = false;
      _error = null;
      _generateNodeId = null;
      _cardEpoch += 1;
      _advancing = false;
    });
    unawaited(_setCardImage(next));
    support.schedulePrefetch(next);
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
    final watched = _watchedJobId;
    final completedHere =
        graph.lastCompletedNodeId == genId && graph.lastCompletedJobType == 'expand_content';
    if (watched == null && !completedHere) return;
    _stopListening();
    _watchedJobId = null;
    // Failed jobs clear the tracker without setting lastCompleted*.
    if (!completedHere) {
      setState(() {
        _generateNodeId = null;
        _loading = false;
        _error = graph.error ?? 'Content generation failed';
      });
      return;
    }
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
    final graph = context.read<GraphController>();
    final support = _supportFor(graph);
    setState(() {
      _advancing = true;
      _loading = true;
      _error = null;
      _quizDone = false;
      _entry = null;
      _cardImageUrl = null;
    });

    // If prefetch already kicked off generation, show that while we wait.
    final peek = support.prefetched;
    if (peek != null && peek.needsGenerate) {
      setState(() {
        _generateNodeId = peek.nodeId;
        _nodeId = peek.nodeId;
        if (peek.title.trim().isNotEmpty) _topicTitle = peek.title;
      });
    }

    // Prefer the card prefetched (and possibly generated) while on the previous one.
    await support.awaitPrefetch();
    if (!mounted) return;
    final prefetched = support.prefetched;
    support.cancelPrefetch();

    if (prefetched != null) {
      if (prefetched.needsGenerate) {
        await _startGenerate(
          graph,
          prefetched.nodeId,
          prefetched.title.isEmpty ? (_topicTitle ?? '') : prefetched.title,
        );
        if (mounted) setState(() => _advancing = false);
        return;
      }
      _applyReady(graph, prefetched);
      return;
    }

    await _loadNext(seed, titleHint: _topicTitle);
    if (mounted) setState(() => _advancing = false);
  }

  @override
  Widget build(BuildContext context) {
    final graph = context.watch<GraphController>();
    final scheme = Theme.of(context).colorScheme;
    final padding = MediaQuery.paddingOf(context);
    final graphUrls = LearningTrackSupport.imageUrlsFromGraph(graph, _nodeId);
    final imageUrl = _cardImageUrl ?? graphUrls.$1 ?? graphUrls.$2;
    final entry = _entry;
    final genId = _generateNodeId;
    final genJob =
        genId == null ? null : graph.jobForNode(genId, type: 'expand_content');
    final generating = genId != null && (genJob != null || entry == null);
    final bottomFadeHeight = padding.bottom + 88 + ProfileTopFade.fadeExtension;

    final Widget cardBody;
    if (generating) {
      final tile = (_topicTitle ?? '').trim();
      cardBody = LearningTrackGeneratingCard(
        topicTitle: tile.isEmpty ? 'this topic' : tile,
        progressMessage: genJob?.progressMessage,
      );
    } else if (_loading || entry == null) {
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
