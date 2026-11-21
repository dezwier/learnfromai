import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/pulse_placeholder.dart';
import '../../../core/widgets/study_card.dart';
import '../../auth/auth_controller.dart';
import '../../profile/overlay_panel_chrome.dart';
import '../graph_controller.dart';
import 'admin_content_delete.dart';
import 'learn_card.dart';
import 'learn_session_chrome.dart';
import 'leitner_distribution_card.dart';

const _checkKinds = ['check1', 'check2', 'check3'];

/// Fullscreen testing-track overlay (Leitner hub + review session).
class TestingTrackSheet extends StatefulWidget {
  const TestingTrackSheet({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  State<TestingTrackSheet> createState() => _TestingTrackSheetState();
}

class _TestingTrackSheetState extends State<TestingTrackSheet> {
  final _rng = math.Random();
  var _loading = true;
  var _refreshing = false;
  var _reviewing = false;
  var _submitting = false;
  String? _error;
  LeitnerDistribution? _distribution;
  List<_ReviewCard> _queue = const [];
  int _queueIndex = 0;
  var _answered = false;
  /// Prevents the cloze Check / keyboard Done tap from also hitting Next/Done.
  var _continueArmed = false;
  int _hubLoadGen = 0;
  int _reviewSessionGen = 0;

  /// Faded hub backdrop: one random topic image, slight rotation.
  String? _backdropUrl;
  Uint8List? _backdropBytes;
  late final double _backdropAngle;
  late final Alignment _backdropAlign;

  @override
  void initState() {
    super.initState();
    // ±6° and a soft off-center crop, locked for this open.
    _backdropAngle = (_rng.nextDouble() * 2 - 1) * (math.pi / 30);
    _backdropAlign = Alignment(
      (_rng.nextDouble() * 2 - 1) * 0.35,
      (_rng.nextDouble() * 2 - 1) * 0.45,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_pickBackdrop());
      unawaited(_loadHub());
    });
  }

  List<String> _topicImageUrls(GraphController graph) {
    final nodes = graph.categoryGraph?['nodes'];
    if (nodes is! List) return const [];
    final urls = <String>[];
    final seen = <String>{};
    for (final raw in nodes) {
      if (raw is! Map) continue;
      final thumb = raw['image_thumb_url']?.toString().trim();
      final full = raw['image_url']?.toString().trim();
      final url = (thumb != null && thumb.isNotEmpty)
          ? thumb
          : ((full != null && full.isNotEmpty) ? full : null);
      if (url == null || !seen.add(url)) continue;
      urls.add(url);
    }
    return urls;
  }

  Future<void> _pickBackdrop() async {
    final graph = context.read<GraphController>();
    final urls = _topicImageUrls(graph);
    if (urls.isEmpty) return;
    final url = urls[_rng.nextInt(urls.length)];
    setState(() => _backdropUrl = url);
    final cached = graph.imageBytesByUrl[url];
    if (cached != null && cached.isNotEmpty) {
      if (!mounted) return;
      setState(() => _backdropBytes = cached);
      return;
    }
    final bytes = await graph.fetchImageBytes(url, notify: false);
    if (!mounted || bytes == null || bytes.isEmpty) return;
    if (_backdropUrl != url) return;
    setState(() => _backdropBytes = Uint8List.fromList(bytes));
  }

  Future<void> _loadHub({bool quiet = false}) async {
    final graph = context.read<GraphController>();
    final gen = ++_hubLoadGen;
    setState(() {
      if (quiet) {
        _refreshing = true;
      } else {
        _loading = true;
      }
      _error = null;
      _reviewing = false;
      _queue = const [];
      _queueIndex = 0;
      _answered = false;
      _continueArmed = false;
    });
    final dist = await graph.fetchReviewDistribution();
    if (!mounted || gen != _hubLoadGen) return;
    setState(() {
      _distribution = dist;
      _loading = false;
      _refreshing = false;
      if (dist == null) {
        _error = graph.error ?? 'Could not load review bins';
      }
    });
  }

  Future<void> _startReview() async {
    final graph = context.read<GraphController>();
    // Invalidate any in-flight hub load so it can't wipe the session.
    _hubLoadGen++;
    final sessionGen = ++_reviewSessionGen;
    setState(() {
      _loading = true;
      _error = null;
      _continueArmed = false;
    });
    final queue = await graph.fetchReviewDue(limit: 10);
    if (!mounted || sessionGen != _reviewSessionGen) return;
    if (queue == null || queue.items.isEmpty) {
      setState(() {
        _loading = false;
        _error = queue == null
            ? (graph.error ?? 'Could not load due cards')
            : null;
      });
      await _loadHub(quiet: true);
      return;
    }
    final cards = <_ReviewCard>[
      for (final item in queue.items)
        if (_pickCheck(item.pack) case final kind?)
          _ReviewCard(item: item, checkKind: kind),
    ];
    if (cards.isEmpty) {
      setState(() {
        _loading = false;
        _error = 'Due packs have no quiz bits';
      });
      return;
    }
    setState(() {
      _queue = cards;
      _queueIndex = 0;
      _answered = false;
      _continueArmed = false;
      _reviewing = true;
      _loading = false;
    });
  }

  String? _pickCheck(TopicPack pack) {
    final available = [
      for (final kind in _checkKinds)
        if (pack.bit(kind) != null) kind,
    ];
    if (available.isEmpty) return null;
    return available[_rng.nextInt(available.length)];
  }

  Future<void> _onAnswer({
    required bool correct,
    int? choiceIndex,
    bool? answerBool,
    String? answerText,
  }) async {
    if (_submitting || _answered) return;
    final card = _queue[_queueIndex];
    final graph = context.read<GraphController>();
    final sessionGen = _reviewSessionGen;
    setState(() {
      _submitting = true;
      _answered = true;
      _continueArmed = false;
    });
    await graph.submitReview(
      nodeId: card.item.nodeId,
      packIndex: card.item.packIndex,
      correct: correct,
      checkKind: card.checkKind,
      choiceIndex: choiceIndex,
      answerBool: answerBool,
      answerText: answerText,
    );
    if (!mounted || sessionGen != _reviewSessionGen) return;
    setState(() => _submitting = false);
    // Arm Next/Done after the submitting tap/keyboard Done has fully settled.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted || sessionGen != _reviewSessionGen || !_answered) return;
    setState(() => _continueArmed = true);
  }

  Future<void> _onNextCard() async {
    if (!_answered || !_continueArmed || _submitting) return;
    if (_queueIndex + 1 >= _queue.length) {
      await _loadHub();
      return;
    }
    setState(() {
      _queueIndex += 1;
      _answered = false;
      _continueArmed = false;
    });
  }

  Future<void> _afterAdminDelete() async {
    if (_queue.isEmpty) {
      await _loadHub();
      return;
    }
    final next = List<_ReviewCard>.from(_queue)..removeAt(_queueIndex);
    if (next.isEmpty) {
      await _loadHub();
      return;
    }
    setState(() {
      _queue = next;
      if (_queueIndex >= next.length) _queueIndex = next.length - 1;
      _answered = false;
      _continueArmed = false;
    });
  }

  String _nextReviewLabel(LeitnerDistribution dist) {
    final raw = dist.firstNextReviewAt;
    if (raw == null || raw.isEmpty) return 'Nothing due yet';
    final when = DateTime.tryParse(raw)?.toLocal();
    if (when == null) return 'Nothing due yet';
    final diff = when.difference(DateTime.now());
    if (diff.isNegative) return 'Cards are due';
    if (diff.inMinutes < 60) return 'Next review in ${diff.inMinutes}m';
    if (diff.inHours < 48) return 'Next review in ${diff.inHours}h';
    return 'Next review in ${diff.inDays}d';
  }

  @override
  Widget build(BuildContext context) {
    final dist = _distribution;
    final dueCount = dist?.dueCount ?? 0;
    final canReview = dueCount > 0 && !_loading;
    final showNext = _reviewing && _answered;
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final bottomClearance = LearnSessionFloatingCta.clearance(
          context,
          visible: showNext,
        ) +
        (showNext ? 0 : keyboardInset);

    return OverlayPanel(
      onDismiss: widget.onClose,
      // Review paints its own close under the flip card so the turn covers chrome.
      showCloseButton: !_reviewing,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _FadedTopicBackdrop(
            bytes: _backdropBytes,
            angle: _backdropAngle,
            alignment: _backdropAlign,
          ),
          SafeArea(
            bottom: false,
            child: _loading
                ? Padding(
                    padding: studyPagePadding.copyWith(bottom: bottomClearance),
                    child: const Column(
                      children: [
                        SizedBox(
                          height: 220,
                          width: double.infinity,
                          child: PulsePlaceholder.image(),
                        ),
                        SizedBox(height: 16),
                        SizedBox(
                          height: 56,
                          width: double.infinity,
                          child: PulsePlaceholder.image(),
                        ),
                      ],
                    ),
                  )
                : _reviewing
                    ? _buildReview(context, bottomClearance)
                    : _buildHub(
                        context,
                        dist,
                        canReview,
                        dueCount,
                        bottomClearance,
                      ),
          ),
          if (showNext)
            LearnSessionFloatingCta(
              label: _queueIndex + 1 >= _queue.length ? 'Done' : 'Next',
              onPressed: (!_submitting && _continueArmed)
                  ? () => unawaited(_onNextCard())
                  : null,
            ),
        ],
      ),
    );
  }

  Widget _buildHub(
    BuildContext context,
    LeitnerDistribution? dist,
    bool canReview,
    int dueCount,
    double bottomClearance,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: studyPagePadding.copyWith(
        top: OverlayPanel.closeSize + OverlayPanel.closeInset,
        bottom: bottomClearance,
      ),
      children: [
        Text(
          'Testing track',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 6),
        Text(
          'Completed packs start in bin 1. Correct moves up; incorrect moves two down. Reach bin 8 to graduate.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.65),
              ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: TextStyle(color: scheme.error)),
        ],
        const SizedBox(height: 18),
        Text(
          'Learning bins',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: scheme.onSurface.withValues(alpha: 0.55),
              ),
        ),
        const SizedBox(height: 8),
        DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: scheme.outline.withValues(alpha: 0.2),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.14),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Stack(
            children: [
              if (_backdropBytes != null)
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Opacity(
                      opacity: 0.22,
                      child: Transform.rotate(
                        angle: _backdropAngle,
                        child: Transform.scale(
                          scale: 1.18,
                          alignment: _backdropAlign,
                          child: Image.memory(
                            _backdropBytes!,
                            fit: BoxFit.cover,
                            alignment: _backdropAlign,
                            gaplessPlayback: true,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (dist == null)
                const SizedBox(
                  height: 220,
                  child: Center(child: Text('No review data yet.')),
                )
              else
                LeitnerDistributionCard(
                  distribution: dist,
                  countsRefreshing: _refreshing,
                ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: canReview ? () => unawaited(_startReview()) : null,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
            textStyle: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          child: Text(
            canReview
                ? 'Review due cards ($dueCount)'
                : (dist == null
                    ? 'Review due cards'
                    : _nextReviewLabel(dist)),
          ),
        ),
      ],
    );
  }

  String? _cardImageUrl(ReviewDueItem item, GraphController graph) {
    final thumb = item.imageThumbUrl?.trim();
    if (thumb != null && thumb.isNotEmpty) return thumb;
    final full = item.imageUrl?.trim();
    if (full != null && full.isNotEmpty) return full;
    final nodes = graph.categoryGraph?['nodes'];
    if (nodes is! List) return null;
    for (final raw in nodes) {
      if (raw is! Map || raw['id']?.toString() != item.nodeId) continue;
      final gThumb = raw['image_thumb_url']?.toString().trim();
      if (gThumb != null && gThumb.isNotEmpty) return gThumb;
      final gFull = raw['image_url']?.toString().trim();
      if (gFull != null && gFull.isNotEmpty) return gFull;
    }
    return null;
  }

  Widget _buildReview(BuildContext context, double bottomClearance) {
    final graph = context.watch<GraphController>();
    final card = _queue[_queueIndex];
    final imageUrl = _cardImageUrl(card.item, graph);
    final entry = LearnDeckEntry(pack: card.item.pack, checkKind: card.checkKind);
    return LearnSessionCardStage(
      title: card.item.title,
      meta: '${_queueIndex + 1} / ${_queue.length}',
      bottomClearance: bottomClearance,
      onClose: () {
        final panel = OverlayPanel.maybeOf(context);
        if (panel != null) {
          panel.dismiss();
        } else {
          widget.onClose();
        }
      },
      card: Builder(
        builder: (context) {
          final flip = LearnFlipCard(
            key: ValueKey(
              'review-$_queueIndex-${card.item.nodeId}-${card.item.packIndex}-${card.checkKind}',
            ),
            entry: entry,
            imageUrl: imageUrl,
            startOnCheck: true,
            imageLoading: graph.isJobTypeActive(card.item.nodeId, 'generate_image'),
            loadImageBytes: (url) => graph.fetchImageBytes(url, notify: false),
            cachedBytes: graph.cachedImageBytes(imageUrl),
            onShown: () {},
            onCheckAnswer: ({
              required bool correct,
              int? choiceIndex,
              bool? answerBool,
              String? answerText,
            }) {
              unawaited(
                _onAnswer(
                  correct: correct,
                  choiceIndex: choiceIndex,
                  answerBool: answerBool,
                  answerText: answerText,
                ),
              );
            },
          );
          final isAdmin = context.watch<AuthController>().user?.isAdmin == true;
          if (!isAdmin || !_answered) return flip;
          return GestureDetector(
            onLongPress: () async {
              final deleted = await showAdminContentDeleteMenu(
                context,
                nodeId: card.item.nodeId,
                pack: card.item.pack,
                checkKind: card.checkKind,
              );
              if (!deleted || !mounted) return;
              await _afterAdminDelete();
            },
            child: flip,
          );
        },
      ),
    );
  }
}

class _FadedTopicBackdrop extends StatelessWidget {
  const _FadedTopicBackdrop({
    required this.bytes,
    required this.angle,
    required this.alignment,
  });

  final Uint8List? bytes;
  final double angle;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    if (bytes == null || bytes!.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Opacity(
              opacity: 0.16,
              child: Transform.rotate(
                angle: angle,
                child: Transform.scale(
                  scale: 1.25,
                  alignment: alignment,
                  child: Image.memory(
                    bytes!,
                    fit: BoxFit.cover,
                    alignment: alignment,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    scheme.surface.withValues(alpha: 0.55),
                    scheme.surface.withValues(alpha: 0.88),
                    scheme.surface.withValues(alpha: 0.96),
                  ],
                  stops: const [0.0, 0.45, 1.0],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReviewCard {
  const _ReviewCard({required this.item, required this.checkKind});

  final ReviewDueItem item;
  final String checkKind;
}
