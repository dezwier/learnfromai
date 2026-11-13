import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/pulse_placeholder.dart';
import 'graph_controller.dart';

Future<void> showLearnSheet(
  BuildContext context, {
  required String nodeId,
  required String title,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) => LearnSheet(nodeId: nodeId, title: title),
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
  GraphController? _graph;

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
    if (!existing.incomplete) {
      setState(() {
        _content = existing;
        _loading = false;
      });
      return;
    }
    setState(() {
      _content = existing;
      _loading = false;
    });
    if (graph.jobForNode(widget.nodeId) != null) {
      _watchedJobId = graph.jobForNode(widget.nodeId)?.jobId;
      _listen(graph);
      return;
    }
    final queued = await graph.enqueueContent(widget.nodeId, title: widget.title);
    if (!mounted) return;
    if (queued == null) {
      setState(() => _error = graph.error ?? 'Could not start content generation');
      return;
    }
    if (!queued.incomplete) {
      setState(() => _content = queued);
      return;
    }
    _watchedJobId = graph.jobForNode(widget.nodeId)?.jobId;
    _listen(graph);
    setState(() => _content = queued);
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
    setState(() {
      _content = next;
      _error = next == null ? (graph.error ?? 'Could not load learning bits') : null;
      _selectedChoice = -1;
      _revealed = false;
    });
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
    final job = graph.jobForNode(widget.nodeId);
    final generating = job != null || (_content?.incomplete == true && _content?.bits.isEmpty == true);
    final height = MediaQuery.sizeOf(context).height * 0.88;

    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Learn',
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
                if (job?.progressMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    job!.progressMessage!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.6),
                        ),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      _error!,
                      style: TextStyle(color: scheme.error, height: 1.35),
                    ),
                  ),
                _BitSection(
                  label: 'Learn',
                  loading: _loading || (generating && _content?.bit('learn') == null),
                  child: _MarkdownBit(bit: _content?.bit('learn')),
                ),
                const SizedBox(height: 14),
                _BitSection(
                  label: 'Example',
                  loading: _loading || (generating && _content?.bit('example') == null),
                  child: _MarkdownBit(bit: _content?.bit('example')),
                ),
                const SizedBox(height: 14),
                _BitSection(
                  label: 'Check',
                  loading: _loading || (generating && _content?.bit('check') == null),
                  child: _CheckBit(
                    bit: _content?.bit('check'),
                    selected: _selectedChoice,
                    revealed: _revealed,
                    onSelect: (index) {
                      if (_revealed) return;
                      setState(() {
                        _selectedChoice = index;
                        _revealed = true;
                      });
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BitSection extends StatelessWidget {
  const _BitSection({
    required this.label,
    required this.loading,
    required this.child,
  });

  final String label;
  final bool loading;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.onSurface.withValues(
        alpha: scheme.brightness == Brightness.dark ? 0.10 : 0.045,
      ),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: scheme.onSurface.withValues(alpha: 0.72),
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 10),
            if (loading)
              const SizedBox(
                height: 110,
                child: PulsePlaceholder(
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                ),
              )
            else
              child,
          ],
        ),
      ),
    );
  }
}

class _MarkdownBit extends StatelessWidget {
  const _MarkdownBit({this.bit});

  final TopicBit? bit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (bit == null) {
      return Text(
        'No content yet.',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.45),
              fontStyle: FontStyle.italic,
            ),
      );
    }
    final title = bit!.body['title']?.toString().trim();
    final markdown = bit!.body['markdown']?.toString().trim() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null && title.isNotEmpty) ...[
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
        ],
        Text(
          _plainMarkdown(markdown),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                height: 1.45,
                color: scheme.onSurface.withValues(alpha: 0.88),
              ),
        ),
      ],
    );
  }
}

class _CheckBit extends StatelessWidget {
  const _CheckBit({
    required this.selected,
    required this.revealed,
    required this.onSelect,
    this.bit,
  });

  final TopicBit? bit;
  final int selected;
  final bool revealed;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (bit == null) {
      return Text(
        'No check yet.',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.45),
              fontStyle: FontStyle.italic,
            ),
      );
    }
    final question = bit!.body['question']?.toString() ?? '';
    final choicesRaw = bit!.body['choices'];
    final choices = [
      if (choicesRaw is List)
        for (final row in choicesRaw) row.toString(),
    ];
    final answerIndex = (bit!.body['answer_index'] as num?)?.toInt() ?? 0;
    final explanation = bit!.body['explanation']?.toString().trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          question,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                height: 1.3,
              ),
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < choices.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _ChoiceTile(
            label: choices[i],
            selected: selected == i,
            revealed: revealed,
            correct: i == answerIndex,
            onTap: () => onSelect(i),
          ),
        ],
        if (revealed && explanation != null && explanation.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            explanation,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurface.withValues(alpha: 0.72),
                  height: 1.4,
                ),
          ),
        ],
      ],
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.label,
    required this.selected,
    required this.revealed,
    required this.correct,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool revealed;
  final bool correct;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Color border = scheme.onSurface.withValues(alpha: 0.12);
    Color fill = Colors.transparent;
    if (revealed && correct) {
      border = scheme.primary.withValues(alpha: 0.55);
      fill = scheme.primary.withValues(alpha: 0.12);
    } else if (revealed && selected && !correct) {
      border = scheme.error.withValues(alpha: 0.55);
      fill = scheme.error.withValues(alpha: 0.10);
    } else if (selected) {
      border = scheme.primary.withValues(alpha: 0.4);
      fill = scheme.primary.withValues(alpha: 0.06);
    }
    return Material(
      color: fill,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: revealed ? null : onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: border),
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.35),
          ),
        ),
      ),
    );
  }
}

String _plainMarkdown(String raw) {
  // Lightweight: keep readable without a markdown package dependency.
  return raw
      .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m.group(1) ?? '')
      .replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m.group(1) ?? '')
      .replaceAll(RegExp(r'^#+\s*', multiLine: true), '')
      .trim();
}
