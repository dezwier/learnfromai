import 'package:flutter/material.dart';

import '../graph_controller.dart';

class GraphSearchBar extends StatelessWidget {
  const GraphSearchBar({
    required this.controller,
    required this.focusNode,
    required this.suggestions,
    required this.onChanged,
    required this.onSubmit,
    required this.onPick,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final List<TopicChoice> suggestions;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmit;
  final ValueChanged<TopicChoice> onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return TextFieldTapRegion(
      child: Material(
        elevation: 8,
        color: scheme.surface,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (suggestions.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                    itemCount: suggestions.length,
                    separatorBuilder: (_, __) => Divider(height: 1, color: scheme.outlineVariant),
                    itemBuilder: (context, index) {
                      final choice = suggestions[index];
                      final subtitle = choice.description?.trim();
                      return ListTile(
                        dense: true,
                        leading: Icon(Icons.north_west, size: 16, color: scheme.onSurfaceVariant),
                        title: Text(
                          choice.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontFamily: 'tt_ramilas'),
                        ),
                        subtitle: (subtitle == null || subtitle.isEmpty)
                            ? null
                            : Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: textTheme.bodySmall?.copyWith(
                                  fontFamily: 'tt_ramilas',
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                        onTap: () => onPick(choice),
                      );
                    },
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: controller,
                        focusNode: focusNode,
                        autofocus: true,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: 'Search a topic',
                          hintStyle: TextStyle(color: scheme.onSurfaceVariant),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                        onChanged: onChanged,
                        onSubmitted: (_) => onSubmit(),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Search',
                      onPressed: onSubmit,
                      color: scheme.onSurfaceVariant,
                      icon: const Icon(Icons.search),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

