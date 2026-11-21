import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/pulse_placeholder.dart';
import '../../auth/auth_controller.dart';
import '../graph_controller.dart';
import 'admin_content_delete.dart';
import 'learn_card.dart';
import 'learn_edge_dismiss.dart';
import 'learn_session_chrome.dart';
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
      _quizDone = false;
      _entry = null;
      _cardImageUrl = null;
    });
    final next = await graph.fetchLearningNext(seedId);
    if (!mounted) return;
    if (next == null) {
      graph.surfaceError(graph.error ?? 'Could not load the next learning card');
      setState(() => _loading = false);
      return;
    }
    if (next.needsGenerate) {
      // Always generate for the topic where this track was opened.
      await _startGenerate(
        graph,
        widget.seedNodeId,
        widget.seedTitle.isEmpty ? (titleHint ?? next.title) : widget.seedTitle,
      );
      return;
    }
    _applyReady(graph, next, trackOpen: trackOpen);
  }

  Future<void> _startGenerate(GraphController graph, String nodeId, String title) async {
    final support = _supportFor(graph);
    support.cancelPrefetch();
    final originId = widget.seedNodeId;
    final originTitle = widget.seedTitle.isEmpty ? title : widget.seedTitle;
    setState(() {
      _loading = true;
      _generateNodeId = originId;
      _topicTitle = originTitle;
      _nodeId = originId;
      _cardImageUrl = null;
    });
    unawaited(
      _setCardImage(LearningNext(status: 'generate', nodeId: originId, title: originTitle)),
    );
    final queued = await graph.enqueueContentForTrack(originId, title: originTitle);
    if (!mounted) return;
    final job = graph.jobForNode(originId, type: 'expand_content');
    if (job != null) {
      _watchedJobId = job.jobId;
      _listen(graph);
      setState(() {});
      return;
    }
    if (queued == null) {
      graph.surfaceError(graph.error ?? 'Could not start content generation');
      setState(() {
        _generateNodeId = null;
        _loading = false;
      });
      return;
    }
    // 200 with existing content — try once more; do not loop generate forever.
    final next = await graph.fetchLearningNext(originId);
    if (!mounted) return;
    if (next != null && next.isReady) {
      _applyReady(graph, next);
      return;
    }
    graph.surfaceError('No new learning pack could be started for $originTitle');
    setState(() {
      _generateNodeId = null;
      _loading = false;
    });
  }

  void _applyReady(GraphController graph, LearningNext next, {bool trackOpen = false}) {
    final pack = next.pack;
    if (pack == null) {
      graph.surfaceError('No learning pack available');
      setState(() => _loading = false);
      return;
    }
    final available = [
      for (final kind in _checkKinds)
        if (pack.bit(kind) != null) kind,
    ];
    if (available.isEmpty) {
      graph.surfaceError('Pack has no quiz');
      setState(() => _loading = false);
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
      _generateNodeId = null;
      _cardEpoch += 1;
      _advancing = false;
    });
    unawaited(_setCardImage(next));
    support.schedulePrefetch(
      next,
      originNodeId: widget.seedNodeId,
      originTitle: widget.seedTitle,
    );
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
      graph.surfaceError(graph.error ?? 'Content generation failed');
      setState(() {
        _generateNodeId = null;
        _loading = false;
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
      _quizDone = false;
      _entry = null;
      _cardImageUrl = null;
    });

    // If prefetch already kicked off generation, show that while we wait.
    final peek = support.prefetched;
    if (peek != null && peek.needsGenerate) {
      setState(() {
        _generateNodeId = widget.seedNodeId;
        _nodeId = widget.seedNodeId;
        _topicTitle = widget.seedTitle.isEmpty ? peek.title : widget.seedTitle;
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
          widget.seedNodeId,
          widget.seedTitle.isEmpty ? (_topicTitle ?? '') : widget.seedTitle,
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
    final graphUrls = LearningTrackSupport.imageUrlsFromGraph(graph, _nodeId);
    final imageUrl = _cardImageUrl ?? graphUrls.$1 ?? graphUrls.$2;
    final entry = _entry;
    final genId = _generateNodeId;
    final genJob =
        genId == null ? null : graph.jobForNode(genId, type: 'expand_content');
    final generating = genId != null && (genJob != null || entry == null);
    final showNext = _quizDone && entry != null && !generating;
    final bottomClearance =
        LearnSessionFloatingCta.clearance(context, visible: showNext);

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
      final flip = LearnFlipCard(
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
      final isAdmin = context.watch<AuthController>().user?.isAdmin == true;
      final nodeId = _nodeId;
      cardBody = (isAdmin && _quizDone && nodeId != null)
          ? GestureDetector(
              onLongPress: () async {
                final deleted = await showAdminContentDeleteMenu(
                  context,
                  nodeId: nodeId,
                  pack: entry.pack,
                  checkKind: entry.checkKind,
                );
                if (!deleted || !mounted) return;
                await _onNext();
              },
              child: flip,
            )
          : flip;
    }

    final title = (_topicTitle ?? '').trim().isEmpty ? 'Learn' : _topicTitle!.trim();

    return Material(
      type: MaterialType.transparency,
      child: LearnEdgeSwipeToDismiss(
        onDismiss: _dismiss,
        child: Stack(
          fit: StackFit.expand,
          children: [
            SafeArea(
              bottom: false,
              child: LearnSessionCardStage(
                title: title,
                bottomClearance: bottomClearance,
                titleColor: Colors.white,
                metaColor: Colors.white.withValues(alpha: 0.75),
                titleShadows: const [
                  Shadow(blurRadius: 8, color: Color(0x88000000)),
                  Shadow(blurRadius: 2, color: Color(0xAA000000)),
                ],
                onClose: _dismiss,
                card: cardBody,
              ),
            ),
            if (showNext)
              LearnSessionFloatingCta(
                label: _advancing ? 'Loading…' : 'Next',
                onPressed: _advancing ? null : () => unawaited(_onNext()),
              ),
          ],
        ),
      ),
    );
  }
}
