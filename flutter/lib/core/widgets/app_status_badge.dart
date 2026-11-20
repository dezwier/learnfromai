import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../features/knowledge_graph/graph_controller.dart';

/// Global bottom status badge for app-wide notices (LLM limits, job failures, …).
///
/// Mount above the navigator so it stays visible over drawers and sheets.
class AppStatusBadgeHost extends StatelessWidget {
  const AppStatusBadgeHost({super.key});

  @override
  Widget build(BuildContext context) {
    final graph = context.watch<GraphController>();
    final message = graph.error?.trim();
    if (message == null || message.isEmpty) return const SizedBox.shrink();

    return AppStatusBadge(
      message: message,
      onDismiss: graph.clearError,
    );
  }
}

/// Clean floating notice pill pinned above the home indicator.
class AppStatusBadge extends StatelessWidget {
  const AppStatusBadge({
    super.key,
    required this.message,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final bottom = media.padding.bottom + media.viewInsets.bottom + 20;
    final dark = scheme.brightness == Brightness.dark;
    final fill = dark ? const Color(0xFF2A2E33) : const Color(0xFFF4F3F1);
    final ink = dark ? const Color(0xFFE8EAEE) : const Color(0xFF2C3036);
    final mute = ink.withValues(alpha: 0.62);
    final accent = dark ? const Color(0xFFC4A35A) : const Color(0xFF8A6E3B);

    return Positioned(
      left: 16,
      right: 16,
      bottom: bottom,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Material(
              color: Colors.transparent,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: accent.withValues(alpha: dark ? 0.35 : 0.28),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: dark ? 0.45 : 0.14),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Icon(
                          Icons.info_outline_rounded,
                          size: 20,
                          color: accent,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          message,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: ink,
                                height: 1.35,
                                fontWeight: FontWeight.w500,
                              ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: 'Dismiss',
                        onPressed: onDismiss,
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 36,
                          minHeight: 36,
                        ),
                        icon: Icon(
                          Icons.close_rounded,
                          size: 18,
                          color: mute,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
