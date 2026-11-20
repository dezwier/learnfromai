import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/pulse_placeholder.dart';
import '../graph_controller.dart';
import 'learn_check_bits.dart';
import 'learn_pack_chrome.dart';
import 'leitner_distribution_card.dart';

const _checkKinds = ['check1', 'check2', 'check3'];

Future<void> showTestingTrack(BuildContext context) {
  return Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierDismissible: true,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (context, animation, secondaryAnimation) {
        return const TestingTrackSheet();
      },
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        if (animation.status == AnimationStatus.reverse) return child;
        final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return FadeTransition(opacity: curved, child: child);
      },
    ),
  );
}

class TestingTrackSheet extends StatefulWidget {
  const TestingTrackSheet({super.key});

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
  var _dismissing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_loadHub());
    });
  }

  Future<void> _loadHub({bool quiet = false}) async {
    final graph = context.read<GraphController>();
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
    });
    final dist = await graph.fetchReviewDistribution();
    if (!mounted) return;
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
    setState(() {
      _loading = true;
      _error = null;
    });
    final queue = await graph.fetchReviewDue(limit: 10);
    if (!mounted) return;
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
        if (_pickCheck(item.pack) != null)
          _ReviewCard(item: item, checkKind: _pickCheck(item.pack)!),
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
    setState(() {
      _submitting = true;
      _answered = true;
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
    if (!mounted) return;
    setState(() => _submitting = false);
  }

  Future<void> _onNextCard() async {
    if (!_answered) return;
    if (_queueIndex + 1 >= _queue.length) {
      await _loadHub();
      return;
    }
    setState(() {
      _queueIndex += 1;
      _answered = false;
    });
  }

  void _dismiss() {
    if (_dismissing || !mounted) return;
    _dismissing = true;
    Navigator.of(context).pop();
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
    final scheme = Theme.of(context).colorScheme;
    final padding = MediaQuery.paddingOf(context);
    final dist = _distribution;
    final dueCount = dist?.dueCount ?? 0;
    final canReview = dueCount > 0 && !_loading;

    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _dismiss,
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            top: padding.top + 48,
            bottom: padding.bottom + 24,
            child: GestureDetector(
              onTap: () {},
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: 0.97),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: scheme.outlineVariant.withValues(alpha: 0.35),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 24,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: 'Close',
                            onPressed: _dismiss,
                            icon: const Icon(Icons.close),
                          ),
                          Expanded(
                            child: Text(
                              _reviewing ? 'Review' : 'Testing track',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                          ),
                          const SizedBox(width: 48),
                        ],
                      ),
                    ),
                    Expanded(
                      child: _loading
                          ? Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                children: [
                                  const SizedBox(
                                    height: 220,
                                    width: double.infinity,
                                    child: PulsePlaceholder.image(),
                                  ),
                                  const SizedBox(height: 16),
                                  const SizedBox(
                                    height: 56,
                                    width: double.infinity,
                                    child: PulsePlaceholder.image(),
                                  ),
                                ],
                              ),
                            )
                          : _reviewing
                              ? _buildReview(context)
                              : _buildHub(context, dist, canReview, dueCount),
                    ),
                  ],
                ),
              ),
            ),
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
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Learning bins',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            'Completed packs start in bin 1. Correct moves up; incorrect moves two down. Reach bin 8 to graduate.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurface.withValues(alpha: 0.65),
                ),
          ),
          const SizedBox(height: 8),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _error!,
                style: TextStyle(color: scheme.error),
              ),
            ),
          Expanded(
            child: dist == null
                ? Center(
                    child: Text(
                      'No review data yet.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurface.withValues(alpha: 0.5),
                          ),
                    ),
                  )
                : SingleChildScrollView(
                    child: LeitnerDistributionCard(
                      distribution: dist,
                      countsRefreshing: _refreshing,
                    ),
                  ),
          ),
          const SizedBox(height: 12),
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
      ),
    );
  }

  Widget _buildReview(BuildContext context) {
    final card = _queue[_queueIndex];
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${_queueIndex + 1} / ${_queue.length}',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurface.withValues(alpha: 0.55),
                ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _ReviewQuizPane(
              key: ValueKey('${card.item.nodeId}:${card.item.packIndex}:$_queueIndex'),
              title: card.item.title,
              pack: card.item.pack,
              checkKind: card.checkKind,
              onAnswer: _onAnswer,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _answered && !_submitting
                ? () => unawaited(_onNextCard())
                : null,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            child: Text(
              _queueIndex + 1 >= _queue.length ? 'Done' : 'Next',
            ),
          ),
        ],
      ),
    );
  }
}

class _ReviewCard {
  const _ReviewCard({required this.item, required this.checkKind});

  final ReviewDueItem item;
  final String checkKind;
}

class _ReviewQuizPane extends StatefulWidget {
  const _ReviewQuizPane({
    super.key,
    required this.title,
    required this.pack,
    required this.checkKind,
    required this.onAnswer,
  });

  final String title;
  final TopicPack pack;
  final String checkKind;
  final Future<void> Function({
    required bool correct,
    int? choiceIndex,
    bool? answerBool,
    String? answerText,
  }) onAnswer;

  @override
  State<_ReviewQuizPane> createState() => _ReviewQuizPaneState();
}

class _ReviewQuizPaneState extends State<_ReviewQuizPane> {
  var _selected = -1;
  var _revealed = false;
  final _clozeController = TextEditingController();

  @override
  void dispose() {
    _clozeController.dispose();
    super.dispose();
  }

  TopicBit? get _bit => widget.pack.bit(widget.checkKind);

  void _revealMc(int choiceIndex) {
    if (_revealed) return;
    final bit = _bit;
    if (bit == null) return;
    final answer = (bit.body['answer_index'] as num?)?.toInt() ?? 0;
    final correct = choiceIndex == answer;
    setState(() {
      _selected = choiceIndex;
      _revealed = true;
    });
    unawaited(widget.onAnswer(correct: correct, choiceIndex: choiceIndex));
  }

  void _revealBool(bool value) {
    if (_revealed) return;
    final bit = _bit;
    if (bit == null) return;
    final answer = bit.body['answer'] == true;
    final correct = value == answer;
    setState(() {
      _selected = value ? 1 : 0;
      _revealed = true;
    });
    unawaited(widget.onAnswer(correct: correct, answerBool: value));
  }

  void _revealCloze() {
    if (_revealed) return;
    final bit = _bit;
    if (bit == null) return;
    final text = _clozeController.text;
    final correct = gradeCloze(bit, text);
    setState(() => _revealed = true);
    unawaited(widget.onAnswer(correct: correct, answerText: text));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final learn = widget.pack.bit('learn');
    final learnTitle = learn?.body['title']?.toString().trim();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            if (learnTitle != null && learnTitle.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                learnTitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.6),
                    ),
              ),
            ],
            const SizedBox(height: 16),
            LearnCheckBit(
              bit: _bit,
              selected: _selected,
              revealed: _revealed,
              clozeController: _clozeController,
              onSelectChoice: _revealMc,
              onSelectBool: _revealBool,
              onSubmitCloze: _revealCloze,
            ),
            if (_revealed) ...[
              const SizedBox(height: 12),
              Text(
                _selectedOutcomeLabel(),
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: _lastCorrect
                          ? learnOkColor(Theme.of(context).brightness)
                          : learnBadColor(Theme.of(context).brightness),
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  bool get _lastCorrect {
    final bit = _bit;
    if (bit == null) return false;
    final type = checkTypeOf(bit);
    if (type == 'true_false') {
      return (_selected == 1) == (bit.body['answer'] == true);
    }
    if (type == 'cloze') {
      return gradeCloze(bit, _clozeController.text);
    }
    final answer = (bit.body['answer_index'] as num?)?.toInt() ?? 0;
    return _selected == answer;
  }

  String _selectedOutcomeLabel() => _lastCorrect ? 'Correct — bin up' : 'Incorrect — bin down';
}
