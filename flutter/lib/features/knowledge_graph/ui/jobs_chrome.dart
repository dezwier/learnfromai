import 'package:flutter/material.dart';

import '../graph_controller.dart';

class JobsBadgeButton extends StatelessWidget {
  const JobsBadgeButton({
    required this.count,
    required this.open,
    required this.onPressed,
  });

  final int count;
  final bool open;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Badge(
      isLabelVisible: count > 0,
      label: Text('$count'),
      child: FloatingActionButton.small(
        heroTag: 'graph-jobs',
        tooltip: open ? 'Hide job queue' : 'Show running jobs',
        backgroundColor: open ? scheme.primary : scheme.surfaceContainerHighest,
        foregroundColor: open ? scheme.onPrimary : scheme.onSurfaceVariant,
        elevation: 1.5,
        focusElevation: 2,
        hoverElevation: 2,
        highlightElevation: 2,
        onPressed: onPressed,
        child: const Icon(Icons.hourglass_top, size: 20),
      ),
    );
  }
}

class JobsPanel extends StatelessWidget {
  const JobsPanel({required this.jobs, required this.onSelect});

  final List<TrackedJob> jobs;
  final ValueChanged<TrackedJob> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 6,
      color: scheme.surface.withValues(alpha: 0.97),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280, maxHeight: 280),
        child: ListView.separated(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 6),
          itemCount: jobs.length,
          separatorBuilder: (_, __) => Divider(
            height: 1,
            color: scheme.onSurface.withValues(alpha: 0.06),
          ),
          itemBuilder: (context, index) {
            final job = jobs[index];
            return InkWell(
              onTap: () => onSelect(job),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      job.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      job.progressMessage ?? job.state,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurface.withValues(alpha: 0.65),
                          ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

