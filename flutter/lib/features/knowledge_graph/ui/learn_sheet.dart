import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../profile/overlay_panel_chrome.dart';
import '../graph_controller.dart';
import '../models.dart';
import 'learn_check_bits.dart';
import 'learn_pack_chrome.dart';

const _lessonKinds = ['learn', 'example', 'check1', 'check2', 'check3'];
const _lessonLabels = ['Learn', 'Example', 'Check 1', 'Check 2', 'Check 3'];
const _checkKinds = {'check1', 'check2', 'check3'};

Future<void> showLearnSheet(
  BuildContext context, {
  required String nodeId,
  required String title,
}) {
  return Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      pageBuilder: (context, animation, secondaryAnimation) {
        return LearnSheet(nodeId: nodeId, title: title);
      },
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
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
  var _selectedChoice = -1;
  var _revealed = false;
  var _step = 0;
  var _packIndex = 1;
  var _generatingAnother = false;
  GraphController? _graph;
  final Set<String> _trackedKinds = {};
  final Set<int> _completedPacks = {};
  final _clozeController = TextEditingController();

  TopicPack? get _activePack => _content?.pack(_packIndex);

  void _mergeCompletedFrom(TopicContent content) {
    _completedPacks.addAll(content.completedPacks);
  }

  void _maybeMarkPackCompleted() {
    final needed = {
      for (final kind in _lessonKinds) _trackKey(kind),
    };
    if (!needed.every(_trackedKinds.contains)) return;
    if (_completedPacks.add(_packIndex)) {
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
    if (existing.packs.isNotEmpty && !existing.incomplete) {
      _applyContent(existing, selectPack: existing.initialPackIndex());
      return;
    }
    if (existing.packs.isNotEmpty) {
      _applyContent(existing, selectPack: existing.initialPackIndex());
    } else {
      setState(() {
        _content = existing;
        _loading = false;
      });
    }
    if (graph.jobForNode(widget.nodeId) != null) {
      _watchedJobId = graph.jobForNode(widget.nodeId)?.jobId;
      _listen(graph);
      return;
    }
    if (!existing.incomplete) return;
    final queued = await graph.enqueueContent(widget.nodeId, title: widget.title);
    if (!mounted) return;
    if (queued == null) {
      setState(() => _error = graph.error ?? 'Could not start content generation');
      return;
    }
    if (queued.packs.isNotEmpty && !queued.incomplete) {
      _applyContent(queued, selectPack: queued.initialPackIndex(extraCompleted: _completedPacks));
      return;
    }
    _watchedJobId = graph.jobForNode(widget.nodeId)?.jobId;
    _listen(graph);
    setState(() => _content = queued);
  }

  void _applyContent(TopicContent content, {required int selectPack}) {
    final pack = content.pack(selectPack) ?? content.packs.firstOrNull;
    setState(() {
      _content = content;
      _mergeCompletedFrom(content);
      _loading = false;
      _error = null;
      _packIndex = pack?.packIndex ?? 1;
      _step = 0;
      _selectedChoice = -1;
      _revealed = false;
      _generatingAnother = false;
      _clozeController.clear();
      _trackedKinds.clear();
    });
    final graph = _graph ?? context.read<GraphController>();
    _maybeTrackView(graph);
  }

  void _onGraphChanged() {
    if (!mounted) return;
    final graph = _graph ?? context.read<GraphController>();
    final active = graph.jobForNode(widget.nodeId);
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
      setState(() {
        _error = graph.error ?? 'Could not load learning bits';
        _generatingAnother = false;
      });
      return;
    }
    final prefer = next.packs.isNotEmpty ? next.packs.last.packIndex : _packIndex;
    _applyContent(next, selectPack: prefer);
  }

  void _dismiss() {
    Navigator.of(context).pop();
  }

  void _goBack() {
    if (_step <= 0) return;
    setState(() {
      _step -= 1;
      _selectedChoice = -1;
      _revealed = false;
      _clozeController.clear();
    });
    final graph = _graph ?? context.read<GraphController>();
    _maybeTrackView(graph);
  }

  void _goContinue() {
    if (_step >= _lessonKinds.length - 1) {
      _maybeMarkPackCompleted();
      _dismiss();
      return;
    }
    setState(() {
      _step += 1;
      _selectedChoice = -1;
      _revealed = false;
      _clozeController.clear();
    });
    final graph = _graph ?? context.read<GraphController>();
    _maybeTrackView(graph);
  }

  void _selectPack(int packIndex) {
    if (_packIndex == packIndex) return;
    setState(() {
      _packIndex = packIndex;
      _step = 0;
      _selectedChoice = -1;
      _revealed = false;
      _clozeController.clear();
      _trackedKinds.clear();
    });
    final graph = _graph ?? context.read<GraphController>();
    _maybeTrackView(graph);
  }

  Future<void> _generateAnother() async {
    final graph = _graph ?? context.read<GraphController>();
    if (graph.jobForNode(widget.nodeId) != null) return;
    if (_content?.allPacksComplete != true) return;
    setState(() {
      _generatingAnother = true;
      _error = null;
    });
    final queued = await graph.enqueueContent(
      widget.nodeId,
      title: widget.title,
      newPack: true,
    );
    if (!mounted) return;
    if (queued == null) {
      setState(() {
        _generatingAnother = false;
        _error = graph.error ?? 'Could not start content generation';
      });
      return;
    }
    // Job queued: keep existing packs visible/playable while the worker runs.
    if (graph.jobForNode(widget.nodeId) != null) {
      _watchedJobId = graph.jobForNode(widget.nodeId)?.jobId;
      _listen(graph);
      setState(() => _generatingAnother = true);
      return;
    }
    // Synchronous complete (rare): refresh packs without wiping the current step.
    if (queued.packs.isNotEmpty) {
      setState(() {
        _content = queued;
        _mergeCompletedFrom(queued);
        _generatingAnother = false;
      });
    }
  }

  String _trackKey(String kind) => '$_packIndex:$kind';

  void _maybeTrackView(GraphController graph) {
    final kind = _lessonKinds[_step];
    if (_checkKinds.contains(kind)) return;
    if (_trackedKinds.contains(_trackKey(kind))) return;
    if (_activePack?.bit(kind) == null) return;
    _trackedKinds.add(_trackKey(kind));
    unawaited(
      graph.trackEvent(
        nodeId: widget.nodeId,
        kind: kind,
        payload: {'pack_index': _packIndex},
      ),
    );
    _maybeMarkPackCompleted();
  }

  void _trackCheckAnswer(
    GraphController graph,
    String kind, {
    required bool correct,
    int? choiceIndex,
    bool? answerBool,
    String? answerText,
  }) {
    if (_trackedKinds.contains(_trackKey(kind))) return;
    if (_activePack?.bit(kind) == null) return;
    _trackedKinds.add(_trackKey(kind));
    unawaited(
      graph.trackEvent(
        nodeId: widget.nodeId,
        kind: kind,
        payload: {
          'pack_index': _packIndex,
          'correct': correct,
          if (choiceIndex != null) 'choice_index': choiceIndex,
          if (answerBool != null) 'answer_bool': answerBool,
          if (answerText != null) 'answer_text': answerText,
        },
      ),
    );
    _maybeMarkPackCompleted();
  }

  void _onSelectMc(GraphController graph, String kind, int choiceIndex) {
    if (_revealed) return;
    final bit = _activePack?.bit(kind);
    final answerIndex = (bit?.body['answer_index'] as num?)?.toInt() ?? 0;
    setState(() {
      _selectedChoice = choiceIndex;
      _revealed = true;
    });
    _trackCheckAnswer(
      graph,
      kind,
      correct: choiceIndex == answerIndex,
      choiceIndex: choiceIndex,
    );
  }

  void _onSelectBool(GraphController graph, String kind, bool value) {
    if (_revealed) return;
    final bit = _activePack?.bit(kind);
    final answer = bit?.body['answer'] == true;
    setState(() {
      _selectedChoice = value ? 1 : 0;
      _revealed = true;
    });
    _trackCheckAnswer(
      graph,
      kind,
      correct: value == answer,
      answerBool: value,
    );
  }

  void _onSubmitCloze(GraphController graph, String kind) {
    if (_revealed) return;
    final bit = _activePack?.bit(kind);
    if (bit == null) return;
    final text = _clozeController.text;
    final correct = gradeCloze(bit, text);
    setState(() => _revealed = true);
    _trackCheckAnswer(
      graph,
      kind,
      correct: correct,
      answerText: text.trim(),
    );
  }

  bool _stepReady({
    required bool generating,
    required String kind,
  }) {
    if (_error != null) return true;
    if (_loading) return false;
    if (_activePack?.bit(kind) != null) return true;
    if (generating) return false;
    return true;
  }

  @override
  void dispose() {
    _stopListening();
    _clozeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final graph = context.watch<GraphController>();
    final scheme = Theme.of(context).colorScheme;
    final job = graph.jobForNode(widget.nodeId);
    final generating = job != null ||
        _generatingAnother ||
        (_content != null && _content!.packs.isEmpty && _content!.incomplete);
    final kind = _lessonKinds[_step];
    final label = _lessonLabels[_step];
    final ready = _stepReady(generating: generating, kind: kind);
    final onCheck = _checkKinds.contains(kind);
    final continueEnabled =
        ready && (!onCheck || _revealed || _activePack?.bit(kind) == null);
    final continueLabel = _step >= _lessonKinds.length - 1 ? 'Done' : 'Continue';
    final bottomClearance = OverlayPanel.bottomClearance(context, hasBottom: true);
    final packs = _content?.packs ?? const <TopicPack>[];
    final allUserCompleted = packs.isNotEmpty &&
        (_content?.allPacksComplete == true) &&
        packs.every((pack) => _completedPacks.contains(pack.packIndex));
    final canGenerateAnother = !generating && allUserCompleted;

    return OverlayPanel(
      onDismiss: _dismiss,
      bottom: OverlayLessonFooter(
        onBack: _step > 0 ? _goBack : null,
        onContinue: _goContinue,
        continueLabel: continueLabel,
        continueEnabled: continueEnabled,
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    packs.isEmpty
                        ? label
                        : '${packs.length} learning${packs.length == 1 ? '' : 's'} · $label',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.55),
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.4,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.title,
                    style: const TextStyle(
                      fontFamily: 'tt_ramilas',
                      fontWeight: FontWeight.w700,
                      fontSize: 26,
                      height: 1.15,
                    ),
                  ),
                  if (packs.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    LearnPackBadgeRow(
                      packs: packs,
                      selectedPackIndex: _packIndex,
                      completedPackIndexes: _completedPacks,
                      onSelectPack: _selectPack,
                    ),
                  ],
                  const SizedBox(height: 12),
                  LearnStepDots(step: _step, total: _lessonKinds.length),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(20, 0, 20, bottomClearance),
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        _error!,
                        style: TextStyle(color: scheme.error, height: 1.35),
                      ),
                    ),
                  if (allUserCompleted || (generating && _generatingAnother)) ...[
                    LearnGenerateAnotherButton(
                      enabled: canGenerateAnother,
                      busy: generating && _generatingAnother,
                      onTap: canGenerateAnother ? () => unawaited(_generateAnother()) : null,
                    ),
                    const SizedBox(height: 12),
                  ],
                  LearnBitSection(
                    label: label,
                    loading: !ready && _error == null,
                    child: onCheck
                        ? LearnCheckBit(
                            bit: _activePack?.bit(kind),
                            selected: _selectedChoice,
                            revealed: _revealed,
                            clozeController: _clozeController,
                            onSelectChoice: (index) => _onSelectMc(graph, kind, index),
                            onSelectBool: (value) => _onSelectBool(graph, kind, value),
                            onSubmitCloze: () => _onSubmitCloze(graph, kind),
                          )
                        : LearnMarkdownBit(bit: _activePack?.bit(kind)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
