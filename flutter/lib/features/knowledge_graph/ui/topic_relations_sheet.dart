import 'package:flutter/material.dart';

import '../layout/graph_layout.dart';

Future<void> showTopicRelationsSheet(
  BuildContext context, {
  required PlacedNode node,
  required GraphLayout? layout,
  required String? focusId,
  required ValueChanged<PlacedNode> onOpenRelated,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Relationships',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                node.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.55),
                    ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: _RelationsList(
                    node: node,
                    layout: layout,
                    focusId: focusId,
                    onOpen: (related) {
                      Navigator.pop(context);
                      onOpenRelated(related);
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _RelationsList extends StatelessWidget {
  const _RelationsList({
    required this.node,
    required this.layout,
    required this.onOpen,
    this.focusId,
  });

  final PlacedNode node;
  final GraphLayout? layout;
  final String? focusId;
  final ValueChanged<PlacedNode> onOpen;

  static const _order = [
    NodeRole.parent,
    NodeRole.sibling,
    NodeRole.child,
    NodeRole.related,
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (layout == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Text(
          'No linked topics in this view.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.45),
                fontStyle: FontStyle.italic,
              ),
        ),
      );
    }
    final groups = relationsFor(node, layout!, focusId: focusId);
    final sections = [
      for (final role in _order)
        if ((groups[role] ?? const []).isNotEmpty) (role, groups[role]!),
    ];
    if (sections.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Text(
          'No linked topics in this view.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.45),
                fontStyle: FontStyle.italic,
              ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < sections.length; i++) ...[
          if (i > 0)
            Divider(
              height: 1,
              thickness: 1,
              color: scheme.onSurface.withValues(alpha: 0.06),
            ),
          _RelationSection(
            role: sections[i].$1,
            nodes: sections[i].$2,
            onOpen: onOpen,
          ),
        ],
      ],
    );
  }
}

class _RelationSection extends StatelessWidget {
  const _RelationSection({
    required this.role,
    required this.nodes,
    required this.onOpen,
  });

  final NodeRole role;
  final List<PlacedNode> nodes;
  final ValueChanged<PlacedNode> onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = roleFill(role, scheme);
    final onAccent = scheme.brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.92)
        : const Color(0xFF1A1C1E).withValues(alpha: 0.88);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                relationSectionLabel(role),
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.72),
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
              ),
            ],
          ),
        ),
        for (final item in nodes)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: item.role == NodeRole.focus
                    ? accent
                    : nodeFill(item, scheme),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _topicInitial(item.title),
                style: TextStyle(
                  color: onAccent,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
            title: Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Icon(
              Icons.chevron_right,
              size: 20,
              color: scheme.onSurface.withValues(alpha: 0.28),
            ),
            onTap: () => onOpen(item),
          ),
      ],
    );
  }
}

String _topicInitial(String title) {
  final trimmed = title.trim();
  if (trimmed.isEmpty) return '?';
  return String.fromCharCode(trimmed.runes.first).toUpperCase();
}
