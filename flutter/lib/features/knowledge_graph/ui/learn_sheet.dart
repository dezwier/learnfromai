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
const _overscrollDismissDistance = 96.0;
const _overscrollPullMax = 220.0;

Future<void> showLearnSheet(
  BuildContext context, {
  required String nodeId,
  required String title,
}) {
  return Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierDismissible: true,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (context, animation, secondaryAnimation) {
        return LearnSheet(nodeId: nodeId, title: title);
      },
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        // Fade in on open; stay opaque on dismiss so edge-swipe can slide off cleanly.
        if (animation.status == AnimationStatus.reverse) {
          return child;
        }
        final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return FadeTransition(opacity: curved, child: child);
      },
    ),
  );
}

class LearnSheet extends StatefulWidget {
  const LearnSheet({super.key, required this.nodeId, required this.title});

  final String nodeId;
  final String title;

  @override
  State<LearnSheet> createState() => _LearnSheetState();
}

class _LearnSheetState extends State<LearnSheet> {
  TopicContent? _content;
  var _loading = true;
  String? _error;
  String? _watchedJobId;
  var _listening = false;
  GraphController? _graph;
  final Set<String> _trackedKinds = {};
  final Set<int> _completedPacks = {};
  List<LearnDeckEntry> _deck = const [];
  final _rng = math.Random();
  var _overscrollPull = 0.0;
  var _dismissing = false;

  void _mergeCompletedFrom(TopicContent content) {
    _completedPacks.addAll(content.completedPacks);
  }

  List<LearnDeckEntry> _buildDeck(TopicContent content) {
    final entries = <LearnDeckEntry>[];
    for (final pack in content.packs) {
      final available = [
        for (final kind in _checkKinds)
          if (pack.bit(kind) != null) kind,
      ];
      if (available.isEmpty) continue;
      final kind = available[_rng.nextInt(available.length)];
      entries.add(LearnDeckEntry(pack: pack, checkKind: kind));
    }
    return entries;
  }

  String _trackKey(int packIndex, String kind) => '$packIndex:$kind';

  void _maybeMarkPackCompleted(int packIndex, String checkKind) {
    final needed = {
      _trackKey(packIndex, 'learn'),
      _trackKey(packIndex, checkKind),
    };
    if (!needed.every(_trackedKinds.contains)) return;
    if (_completedPacks.add(packIndex)) {
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_bootstrap());
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

  Future<void> _bootstrap() async {
    final graph = context.read<GraphController>();
    _graph = graph;
    setState(() {
      _loading = true;
      _error = null;
    });
    final existing = await graph.fetchContent(widget.nodeId);
    if (!mounted) return;
    if (existing == null) {
      setState(() {
        _loading = false;
        _error = graph.error ?? 'Could not load learning bits';
      });
      return;
    }
    if (existing.packs.isNotEmpty) {
      _applyContent(existing);
    } else {
      // No auto-generate — packs are started from the topic action drawer.
      setState(() {
        _content = existing;
        _deck = const [];
        _loading = false;
      });
    }
    final contentJob = graph.jobForNode(widget.nodeId, type: 'expand_content');
    if (contentJob != null) {
      _watchedJobId = contentJob.jobId;
      _listen(graph);
    }
  }

  void _applyContent(TopicContent content) {
    setState(() {
      _content = content;
      _mergeCompletedFrom(content);
      _deck = _buildDeck(content);
      _loading = false;
      _error = null;
      _trackedKinds.clear();
    });
  }

  void _onGraphChanged() {
    if (!mounted) return;
    final graph = _graph ?? context.read<GraphController>();
    final active = graph.jobForNode(widget.nodeId, type: 'expand_content');
    if (active != null) {
      _watchedJobId = active.jobId;
      setState(() {});
      return;
    }
    if (_watchedJobId == null && graph.lastCompletedNodeId != widget.nodeId) {
      return;
    }
    _stopListening();
    _watchedJobId = null;
    unawaited(_reloadAfterJob());
  }

  Future<void> _reloadAfterJob() async {
    final graph = _graph ?? context.read<GraphController>();
    final next = await graph.fetchContent(widget.nodeId);
    if (!mounted) return;
    if (next == null) {
      setState(() => _error = graph.error ?? 'Could not load learning bits');
      return;
    }
    _applyContent(next);
  }

  void _dismiss() {
    if (_dismissing || !mounted) return;
    _dismissing = true;
    Navigator.of(context).pop();
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;

    // Only user-driven overscroll (not the bounce spring) can dismiss.
    if (notification is OverscrollNotification &&
        notification.dragDetails != null) {
      final next =
          (_overscrollPull + notification.overscroll).clamp(-_overscrollPullMax, _overscrollPullMax);
      if (next != _overscrollPull) {
        setState(() => _overscrollPull = next);
      }
      if (next.abs() >= _overscrollDismissDistance) {
        _dismiss();
      }
      return false;
    }

    if (notification is ScrollUpdateNotification) {
      final metrics = notification.metrics;
      final inRange = metrics.pixels > metrics.minScrollExtent &&
          metrics.pixels < metrics.maxScrollExtent;
      if (inRange && _overscrollPull != 0) {
        setState(() => _overscrollPull = 0);
      }
      return false;
    }

    if (notification is ScrollEndNotification) {
      if (_overscrollPull.abs() >= _overscrollDismissDistance) {
        _dismiss();
      } else if (_overscrollPull != 0) {
        setState(() => _overscrollPull = 0);
      }
    }
    return false;
  }

  void _trackLearn(GraphController graph, LearnDeckEntry entry) {
    final key = _trackKey(entry.packIndex, 'learn');
    if (_trackedKinds.contains(key)) return;
    if (entry.pack.bit('learn') == null) return;
    _trackedKinds.add(key);
    unawaited(
      graph.trackEvent(
        nodeId: widget.nodeId,
        kind: 'learn',
        payload: {'pack_index': entry.packIndex},
      ),
    );
    _maybeMarkPackCompleted(entry.packIndex, entry.checkKind);
  }

  void _trackCheck(
    GraphController graph,
    LearnDeckEntry entry, {
    required bool correct,
    int? choiceIndex,
    bool? answerBool,
    String? answerText,
  }) {
    final key = _trackKey(entry.packIndex, entry.checkKind);
    if (_trackedKinds.contains(key)) return;
    if (entry.pack.bit(entry.checkKind) == null) return;
    _trackedKinds.add(key);
    unawaited(
      graph.trackEvent(
        nodeId: widget.nodeId,
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
    _maybeMarkPackCompleted(entry.packIndex, entry.checkKind);
  }

  (String?, String?) _imageUrls(GraphController graph) {
    final nodes = graph.categoryGraph?['nodes'];
    if (nodes is! List) return (null, null);
    for (final raw in nodes) {
      if (raw is Map && raw['id']?.toString() == widget.nodeId) {
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
  void dispose() {
    _stopListening();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final graph = context.watch<GraphController>();
    final scheme = Theme.of(context).colorScheme;
    final job = graph.jobForNode(widget.nodeId, type: 'expand_content');
    final generating = job != null ||
        (_content != null && _content!.packs.isEmpty && _content!.incomplete);
    final urls = _imageUrls(graph);
    final imageUrl = urls.$1 ?? urls.$2;
    final padding = MediaQuery.paddingOf(context);
    final listPadding = EdgeInsets.fromLTRB(
      20,
      padding.top + 12,
      20,
      padding.bottom + 24,
    );

    const scrollPhysics = AlwaysScrollableScrollPhysics(
      parent: BouncingScrollPhysics(),
    );
    Widget body;
    if (_loading && _deck.isEmpty) {
      body = ListView(
        physics: scrollPhysics,
        padding: listPadding,
        children: const [
          PulsePlaceholder.image(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
          SizedBox(height: 12),
          SizedBox(
            height: 120,
            child: PulsePlaceholder(
              borderRadius: BorderRadius.all(Radius.circular(16)),
            ),
          ),
        ],
      );
    } else {
      body = ListView.builder(
        physics: scrollPhysics,
        padding: listPadding,
        itemCount: _deck.length + (generating && _deck.isEmpty ? 1 : 0),
        itemBuilder: (context, index) {
          if (generating && _deck.isEmpty && index == 0) {
            return const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: SizedBox(
                height: 220,
                child: PulsePlaceholder(
                  borderRadius: BorderRadius.all(Radius.circular(16)),
                ),
              ),
            );
          }
          final entry = _deck[index];
          return LearnFlipCard(
            key: ValueKey('pack-${entry.packIndex}-${entry.checkKind}'),
            entry: entry,
            imageUrl: imageUrl,
            imageLoading: graph.isJobTypeActive(widget.nodeId, 'generate_image'),
            loadImageBytes: (url) => graph.fetchImageBytes(url, notify: false),
            cachedBytes: graph.cachedImageBytes(imageUrl),
            completed: _completedPacks.contains(entry.packIndex),
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
        },
      );
    }

    final bottomFadeHeight = padding.bottom + 56 + ProfileTopFade.fadeExtension;
    final pullT = (_overscrollPull.abs() / _overscrollDismissDistance).clamp(0.0, 1.0);

    return Material(
      type: MaterialType.transparency,
      child: LearnEdgeSwipeToDismiss(
        onDismiss: _dismiss,
        child: Stack(
          children: [
            Positioned.fill(
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScrollNotification,
                child: Transform.translate(
                  // Negative overscroll (pull down at top) → content moves down.
                  offset: Offset(0, -_overscrollPull * 0.45),
                  child: Opacity(
                    opacity: 1 - (0.28 * pullT),
                    child: body,
                  ),
                ),
              ),
            ),
            // Same top/bottom fades as the graph chrome.
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
                      shadows: const [
                        Shadow(blurRadius: 6, color: Colors.black45),
                      ],
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
