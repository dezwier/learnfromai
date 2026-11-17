import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/pulse_placeholder.dart';
import '../../../core/widgets/study_card.dart';
import '../../knowledge_graph/graph_controller.dart';
import 'topic_affinity_map.dart';
import 'topic_affinity_models.dart';

/// Recent-study card: loads topic affinity and renders cluster badges.
class TopicAffinityCard extends StatefulWidget {
  const TopicAffinityCard({super.key, required this.onOpenTopic});

  final ValueChanged<String> onOpenTopic;

  @override
  State<TopicAffinityCard> createState() => _TopicAffinityCardState();
}

class _TopicAffinityCardState extends State<TopicAffinityCard> {
  TopicAffinityPayload? _payload;
  var _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_load());
    });
  }

  Future<void> _load() async {
    final graph = context.read<GraphController>();
    setState(() {
      _loading = true;
      _error = null;
    });
    final raw = await graph.fetchTopicAffinity();
    if (!mounted) return;
    setState(() {
      if (raw == null) {
        _payload = null;
        _loading = false;
        _error = graph.error ?? 'Could not load topics';
        return;
      }
      _payload = TopicAffinityPayload.fromJson(raw);
      _loading = false;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget footer;
    if (_loading) {
      footer = SizedBox(
        height: affinityMapHeight,
        width: double.infinity,
        child: PulsePlaceholder.image(borderRadius: BorderRadius.circular(20)),
      );
    } else if (_error != null) {
      footer = Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(
          _error!,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.error,
                height: 1.35,
              ),
        ),
      );
    } else if (_payload == null || _payload!.isEmpty) {
      footer = Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Text(
          'Study a few topics to grow your map.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.62),
                height: 1.35,
              ),
        ),
      );
    } else {
      footer = TopicAffinityMap(
        payload: _payload!,
        onOpenTopic: widget.onOpenTopic,
      );
    }

    return StudyCard(
      eyebrow: 'TOPICS',
      title: 'Learning about',
      footer: footer,
    );
  }
}
